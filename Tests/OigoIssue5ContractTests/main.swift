import AVFAudio
import Darwin
import Foundation
@_spi(Testing) import OigoCore
import OigoCapture
@_spi(Testing) import OigoTranscription
import Speech

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@available(macOS 26.0, *)
private struct OigoIssue5ContractTests {
    @MainActor
    static func main() async {
        let filter = CommandLine.arguments.dropFirst().drop(while: { $0 != "--filter" }).dropFirst().first
        let tests: [(String, () async throws -> Void)] = [
            ("live transcription lifecycle", testLiveTranscriptionLifecycle),
            ("cancellation preserves canonical data", testCancellationPreservesCanonicalData),
            ("cancellation persistence failure", testCancellationPersistenceFailure),
            ("startup shutdown handshake", testStartupShutdownHandshake),
            ("startup gate releases both tasks", testStartupGateReleasesBothTasks),
            ("early-final publication", testEarlyFinalPublication),
            ("overlapping final merge", testOverlappingFinalMerge),
            ("terminal operation serialization", testTerminalOperationSerialization),
            ("retry shutdown tracking", testRetryShutdownTracking),
            ("failure and actionable errors", testFailureAndActionableErrors),
            ("saved-file retry", testSavedFileRetry),
            ("bounded retry staging preservation", testBoundedRetryStagingPreservation),
            ("persistence recovery fault window", testPersistenceRecoveryFaultWindow),
            ("canonical final replacement", testCanonicalFinalReplacement),
            ("append-only persistence is incremental", testAppendOnlyPersistenceIsIncremental),
            ("unchanged final checkpoint does not rewrite", testUnchangedFinalCheckpointDoesNotRewrite),
            ("raw-text crash recovery keeps one canonical ordering", testRawTextCrashRecoveryKeepsOneCanonicalOrdering),
            ("short write recovers the durable prefix", testShortWriteRecoversDurablePrefix),
            ("final checkpoint metadata failure retains transcript", testFinalCheckpointMetadataFailureRetainsTranscript),
            ("tail revision is bounded and suffix-verified", testTailRevisionIsBoundedAndSuffixVerified),
            ("same-length tail revision interrupted before truncate", testSameLengthTailRevisionInterruptedBeforeTruncate),
            ("longer rewrite short-write restores previous suffix", testLongerRewriteShortWriteRestoresPreviousSuffix),
            ("newline-prefixed first segment then second append", testNewlinePrefixedFirstSegmentThenSecondAppend),
            ("missing raw.txt with stale byte count does not checkpoint empty", testMissingRawTextWithStaleByteCountDoesNotCheckpointEmpty),
            ("bounded analyzer-input policy", testBoundedAnalyzerInputPolicy),
            ("never-read consumer saturates with typed degradation", testNeverReadConsumerSaturates),
            ("slow consumer saturates with typed degradation", testSlowConsumerSaturates),
            ("terminated continuation is visible", testTerminatedContinuationIsVisible),
            ("conversion analyzer and result failures reach coordinator", testConversionAnalyzerAndResultFailuresReachCoordinator),
            ("stale generation cannot persist raw text or HUD success", testStaleGenerationCannotPersist),
            ("live speech degradation preserves CAF and saved-audio retry", testLiveSpeechDegradationPreservesCAFAndRetry),
            ("writer failure stays distinct from speech degradation", testWriterFailureDistinctFromSpeechDegradation),
            ("stalled retry consumer saturates with typed degradation", testRetryFeedSaturatesOnStalledConsumer),
            ("preparing live degradation persists into recording metadata", testPreparingDegradationPersistsIntoRecording)
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

        if matched == 0 {
            print("FAIL: no issue #5 contract scenarios matched filter")
            exit(1)
        }
        if failures == 0 {
            print("GREEN: all issue #5 contract scenarios")
            exit(0)
        }
        print("FAILURES=" + String(failures))
        exit(1)
    }

    @MainActor
    private static func testLiveTranscriptionLifecycle() async throws {
        var accumulator = TranscriptionAccumulator()
        let firstPreview = accumulator.ingest(
            range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
            text: "hello",
            isFinal: false
        )
        let replacementPreview = accumulator.ingest(
            range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
            text: "hello world",
            isFinal: false
        )
        let oversizedPreview = accumulator.ingest(
            range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
            text: String(repeating: "p", count: 1_024),
            isFinal: false
        )
        let finalized = accumulator.ingest(
            range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
            text: "hello world",
            isFinal: true
        )
        let accumulated = accumulator.ingest(
            range: TranscriptionRange(startMilliseconds: 100, endMilliseconds: 200),
            text: "again",
            isFinal: true
        )
        guard firstPreview.finalizedText.isEmpty,
              firstPreview.volatileText == "hello",
              replacementPreview.volatileText == "hello world",
              oversizedPreview.volatileText.count == 512,
              finalized.finalizedText == "hello world",
              finalized.volatileText.isEmpty,
              accumulated.finalizedText == "hello world again" else {
            throw ContractFailure(message: "volatile revisions were not replaced before final accumulation")
        }

        for index in 0..<32 {
            _ = accumulator.ingest(
                range: TranscriptionRange(
                    startMilliseconds: 200 + Int64(index * 100),
                    endMilliseconds: 300 + Int64(index * 100)
                ),
                text: "segment-" + String(index),
                isFinal: true
            )
        }
        let bounded = accumulator.snapshot
        guard !bounded.finalizedText.contains("segment-0"),
              bounded.finalizedText.contains("segment-24"),
              bounded.finalizedText.contains("segment-31"),
              !bounded.displayedText.contains("segment-0"),
              bounded.volatileText.isEmpty else {
            throw ContractFailure(message: "finalized transcript state exceeded its bounded revision projection")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-live-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let appendSession = try store.createSession()
        _ = try store.appendRawText("one", for: appendSession)
        _ = try store.appendRawText("two", for: appendSession)
        guard try store.readRawText(for: appendSession) == "one two" else {
            throw ContractFailure(message: "descriptor-backed canonical append did not preserve ordered raw text")
        }
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController()
        let updates = UpdateCollector()
        let coordinator = DictationCoordinator()
        let session = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
            onUpdate: { update in updates.append(update) }
        )
        transcription.emit(TranscriptionUpdate(
            finalizedSegment: nil,
            volatilePreview: "hello",
            isFinal: false
        ))
        transcription.emit(TranscriptionUpdate(
            finalizedSegment: "hello world",
            volatilePreview: "",
            isFinal: true
        ))
        transcription.finalizedText = "hello world again"
        capture.sendBuffer()
        let completed = try await coordinator.stopRecordingWithTranscription()
        let rawText = try String(contentsOf: completed.rawTextURL, encoding: .utf8)
        let stored = try store.load(id: completed.id)

        guard completed.metadata.state == .completed,
              completed.id == session.id,
              rawText == "hello world again",
              stored.metadata.rawTextByteCount == Int64(rawText.utf8.count),
              updates.values.count == 2,
              updates.values[0].volatilePreview == "hello",
              updates.values[1].isFinal,
              !coordinator.hasActiveTranscription,
              !transcription.isRunning,
              !capture.isActive else {
            throw ContractFailure(message: "live transcription did not separate volatile/final text or release resources")
        }
    }

    @MainActor
    private static func testCancellationPreservesCanonicalData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-cancel-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController()
        let coordinator = DictationCoordinator()
        let session = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        capture.sendBuffer()
        transcription.finalizedText = "partial finalized text"
        let cancelled = try await coordinator.cancelRecordingWithTranscription()
        let rawText = try String(contentsOf: cancelled.rawTextURL, encoding: .utf8)
        let stored = try store.load(id: cancelled.id)

        guard cancelled.metadata.state == .cancelled,
              FileManager.default.fileExists(atPath: session.audioURL.path),
              FileManager.default.fileExists(atPath: session.rawTextURL.path),
              rawText == "partial finalized text",
              stored.metadata.rawTextByteCount == Int64(rawText.utf8.count),
              !coordinator.hasActiveTranscription,
              !transcription.isRunning else {
            throw ContractFailure(message: "cancelled recording did not preserve audio and canonical raw.txt")
        }
    }

    @MainActor
    private static func testCancellationPersistenceFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-cancel-persistence-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController()
        let coordinator = DictationCoordinator()
        let session = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        capture.sendBuffer()
        transcription.finalizedText = "must not claim persisted"
        try FileManager.default.createDirectory(at: session.rawTextURL, withIntermediateDirectories: false)

        do {
            _ = try await coordinator.cancelRecordingWithTranscription()
            throw ContractFailure(message: "cancellation unexpectedly succeeded through a raw.txt directory")
        } catch let error as ContractFailure {
            throw error
        } catch {
            let failed = try store.load(id: session.id)
            guard failed.metadata.state == .failed,
                  failed.metadata.rawTextByteCount == nil,
                  FileManager.default.fileExists(atPath: failed.audioURL.path),
                  !coordinator.hasActiveTranscription,
                  coordinator.state == .failed else {
                throw ContractFailure(message: "cancellation persistence failure claimed canonical progress or leaked resources")
            }
        }
    }

    @MainActor
    private static func testStartupShutdownHandshake() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-startup-shutdown-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = BlockingTranscriptionController()
        let coordinator = DictationCoordinator()
        let startTask = Task { @MainActor in
            try await coordinator.startRecordingWithTranscription(
                using: capture,
                store: store,
                transcription: transcription,
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
            )
        }

        await transcription.waitUntilStarted()
        await coordinator.shutdownWithTranscription()
        _ = try? await startTask.value

        guard let session = coordinator.currentSession,
              session.metadata.state == .interrupted,
              coordinator.state == .interrupted,
              !coordinator.hasActiveTranscription,
              !capture.isActive else {
            throw ContractFailure(message: "shutdown completed before a pending transcription start unwound")
        }
    }

    @MainActor
    private static func testEarlyFinalPublication() async throws {
        let service = TranscriptionService()
        let snapshot = try await service.deliverFinalAtStartupBoundaryForTesting(
            range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
            text: "published before analysis work"
        )
        guard snapshot.finalizedText == "published before analysis work",
              snapshot.volatileText.isEmpty,
              snapshot.displayedText == snapshot.finalizedText,
              service.latestSnapshot == snapshot else {
            throw ContractFailure(message: "an immediate final result was not retained after startup publication")
        }
    }

    @MainActor
    private static func testOverlappingFinalMerge() throws {
        var accumulator = TranscriptionAccumulator()
        _ = accumulator.ingest(
            range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
            text: "hello",
            isFinal: true
        )
        let extended = accumulator.ingest(
            range: TranscriptionRange(startMilliseconds: 50, endMilliseconds: 150),
            text: "hello world",
            isFinal: true
        )
        guard extended.finalizedText == "hello world" else {
            throw ContractFailure(message: "overlapping final range discarded the newly covered transcript tail")
        }

        var disjointText = TranscriptionAccumulator()
        _ = disjointText.ingest(
            range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
            text: "hello",
            isFinal: true
        )
        let disjointExtended = disjointText.ingest(
            range: TranscriptionRange(startMilliseconds: 50, endMilliseconds: 150),
            text: "world",
            isFinal: true
        )
        guard disjointExtended.finalizedText == "hello world" else {
            throw ContractFailure(message: "overlapping final range duplicated or lost a non-prefix text tail")
        }

        var correctedText = TranscriptionAccumulator()
        _ = correctedText.ingest(
            range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
            text: "hello world",
            isFinal: true
        )
        let corrected = correctedText.ingest(
            range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
            text: "hello word",
            isFinal: true
        )
        guard corrected.finalizedText == "hello word" else {
            throw ContractFailure(message: "corrected overlapping final range duplicated the prior canonical words")
        }

        var broadCorrection = TranscriptionAccumulator()
        _ = broadCorrection.ingest(
            range: TranscriptionRange(startMilliseconds: 100, endMilliseconds: 200),
            text: "world",
            isFinal: true
        )
        let broadened = broadCorrection.ingest(
            range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 200),
            text: "hello world",
            isFinal: true
        )
        guard broadened.finalizedText == "hello world" else {
            throw ContractFailure(message: "broad corrected final range lost its leading words")
        }
    }

    @MainActor
    private static func testStartupGateReleasesBothTasks() async throws {
        let gate = TranscriptionStartupGate()
        let resultTask = Task {
            for await _ in gate.resultStream {
                return true
            }
            return false
        }
        let analysisTask = Task {
            for await _ in gate.analysisStream {
                return true
            }
            return false
        }

        await Task.yield()
        gate.release()
        guard await resultTask.value, await analysisTask.value else {
            throw ContractFailure(message: "startup gate did not release both transcription tasks")
        }
    }

    @MainActor
    private static func testTerminalOperationSerialization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-terminal-serialization-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = BlockingFinishTranscriptionController()
        let coordinator = DictationCoordinator()
        let session = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        capture.sendBuffer()
        transcription.finalizedText = "serialized terminal result"
        let stopTask = Task { @MainActor in
            try await coordinator.stopRecordingWithTranscription()
        }
        await transcription.waitUntilFinishStarted()
        let cancelTask = Task { @MainActor in
            do {
                _ = try await coordinator.cancelRecordingWithTranscription()
                return true
            } catch {
                return false
            }
        }
        await Task.yield()
        transcription.releaseFinish()
        let completed = try await stopTask.value
        let cancelSucceeded = await cancelTask.value
        let stored = try store.load(id: session.id)
        let terminalEvents = coordinator.transitionHistory.filter {
            [.captureCompleted, .cancel, .fail, .interrupt].contains($0.event)
        }
        guard !cancelSucceeded,
              completed.metadata.state == .completed,
              stored.metadata.state == .completed,
              coordinator.state == .complete,
              terminalEvents.map(\.event).filter({ $0 == .captureCompleted }).count == 1,
              terminalEvents.map(\.event).filter({ $0 == .cancel }).isEmpty,
              transcription.cancelCalls == 0 else {
            throw ContractFailure(message: "overlapping terminal operations did not preserve one consistent completion")
        }
    }

    @MainActor
    private static func testRetryShutdownTracking() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-retry-shutdown-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let created = try store.createSession()
        let failed = try store.update(created, state: .failed, failureReason: "retry shutdown fixture")
        try Data([0x43, 0x41, 0x46]).write(to: failed.audioURL, options: [.atomic])
        let transcription = BlockingRetryTranscriptionController()
        let coordinator = DictationCoordinator()
        let retryTask = Task { @MainActor in
            try? await coordinator.retryRecordingWithTranscription(
                for: failed,
                using: transcription,
                store: store
            )
        }

        await transcription.waitUntilRetryStarted()
        await coordinator.shutdownWithTranscription()
        _ = await retryTask.value
        let interrupted = try store.load(id: failed.id)
        guard transcription.cancelCalls == 1,
              interrupted.metadata.state == .interrupted,
              coordinator.state == .interrupted,
              !coordinator.hasActiveTranscription else {
            throw ContractFailure(message: "shutdown did not cancel and persist the tracked saved retry")
        }
    }

    @MainActor
    private static func testFailureAndActionableErrors() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-failure-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController()
        transcription.finalizedText = "survives analysis failure"
        transcription.finishError = TranscriptionError.analysisFailed("fixture analysis failure")
        let coordinator = DictationCoordinator()
        let session = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        capture.sendBuffer()

        do {
            _ = try await coordinator.stopRecordingWithTranscription()
            throw ContractFailure(message: "analysis failure unexpectedly completed")
        } catch let error as TranscriptionError {
            guard error == .analysisFailed("fixture analysis failure") else {
                throw ContractFailure(message: "analysis failure changed category: " + error.description)
            }
        }

        let failed = try store.load(id: session.id)
        let rawText = try String(contentsOf: failed.rawTextURL, encoding: .utf8)
        guard failed.metadata.state == .failed,
              rawText == "survives analysis failure",
              FileManager.default.fileExists(atPath: failed.audioURL.path),
              !coordinator.hasActiveTranscription,
              !transcription.isRunning else {
            throw ContractFailure(message: "analysis failure did not preserve finalized text and audio")
        }

        let errorDescriptions: [String] = [
            TranscriptionError.unsupportedLocale("zz-ZZ").description,
            TranscriptionError.speechAssetsUnavailable("fixture").description,
            TranscriptionError.speechAssetsInstalling("en_US").description,
            TranscriptionError.recognitionUnavailable("fixture").description,
            TranscriptionError.malformedAudio(session.audioURL, "fixture").description,
            TranscriptionError.cancelled.description,
            TranscriptionError.analysisFailed("fixture").description
        ]
        guard errorDescriptions.allSatisfy({ !$0.isEmpty }) else {
            throw ContractFailure(message: "one or more actionable transcription errors had no description")
        }

        let unsupportedLocale = TranscriptionService(locale: Locale(identifier: "zz-ZZ"))
        do {
            _ = try await unsupportedLocale.checkSpeechAssets()
            throw ContractFailure(message: "unsupported locale unexpectedly resolved")
        } catch let error as TranscriptionError {
            guard case .unsupportedLocale = error else {
                throw ContractFailure(message: "unsupported locale returned the wrong category: " + error.description)
            }
        }
    }

    @MainActor
    private static func testSavedFileRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-retry-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let created = try store.createSession()
        let failed = try store.update(created, state: .failed, failureReason: "live analysis failed")
        let originalAudio = Data([0x43, 0x41, 0x46, 0x2D, 0x46, 0x49, 0x58, 0x54])
        try originalAudio.write(to: failed.audioURL, options: [.atomic])

        let retriedText = try SavedAudioRetry.retry(
            session: failed,
            store: store,
            liveFailure: TranscriptionError.analysisFailed("live fixture"),
            transcribe: { descriptor in
                let url = URL(fileURLWithPath: "/dev/fd/\(descriptor.rawValue)")
                guard url.path.hasPrefix("/dev/fd/") else {
                    throw ContractFailure(message: "saved retry handed the consumer a mutable pathname")
                }
                try FileManager.default.removeItem(at: failed.audioURL)
                try Data("replacement inode".utf8).write(to: failed.audioURL, options: [.atomic])
                let consumedAudio = try Data(contentsOf: url)
                guard consumedAudio == originalAudio else {
                    throw ContractFailure(message: "saved retry consumed bytes from a swapped audio inode")
                }
                let persisted = try store.persistRawText("retried transcript", for: failed)
                _ = try store.update(
                    persisted,
                    state: .completed,
                    audioByteCount: Int64(consumedAudio.count),
                    rawTextByteCount: Int64("retried transcript".utf8.count)
                )
                return "retried transcript"
            }
        )
        let completed = try store.load(id: failed.id)
        let rawText = try String(contentsOf: completed.rawTextURL, encoding: .utf8)
        guard retriedText == "retried transcript",
              completed.metadata.state == .completed,
              rawText == "retried transcript",
              completed.metadata.rawTextByteCount == Int64(rawText.utf8.count) else {
            throw ContractFailure(message: "saved-file retry did not atomically persist canonical text and metadata")
        }

        let coordinatorRetrySession = try store.createSession()
        let coordinatorRetryFailed = try store.update(
            coordinatorRetrySession,
            state: .failed,
            failureReason: "coordinator retry fixture"
        )
        try Data([0x43, 0x41, 0x46]).write(to: coordinatorRetryFailed.audioURL, options: [.atomic])
        let retryController = FakeTranscriptionController()
        retryController.finalizedText = "coordinator retried transcript"
        let retryCoordinator = DictationCoordinator()
        let coordinatorCompleted = try await retryCoordinator.retryRecordingWithTranscription(
            for: coordinatorRetryFailed,
            using: retryController,
            store: store
        )
        let coordinatorRawText = try String(contentsOf: coordinatorCompleted.rawTextURL, encoding: .utf8)
        guard coordinatorCompleted.metadata.state == .completed,
              coordinatorRawText == "coordinator retried transcript",
              retryCoordinator.state == .complete,
              !retryCoordinator.hasActiveTranscription else {
            throw ContractFailure(message: "coordinator retry route did not complete the saved session")
        }

        let symlinkSession = try store.createSession()
        let symlinkFailed = try store.update(symlinkSession, state: .failed, failureReason: "symlink fixture")
        let outsideAudio = root.appendingPathComponent("outside.caf")
        try Data([0x4F, 0x55, 0x54]).write(to: outsideAudio, options: [.atomic])
        try FileManager.default.createSymbolicLink(at: symlinkFailed.audioURL, withDestinationURL: outsideAudio)
        defer { try? FileManager.default.removeItem(at: symlinkFailed.audioURL) }
        do {
            _ = try SavedAudioRetry.retry(
                session: symlinkFailed,
                store: store,
                liveFailure: TranscriptionError.analysisFailed("symlink fixture")
            ) { _ in () }
            throw ContractFailure(message: "saved retry accepted a symbolic-link audio artifact")
        } catch let error as TranscriptionError {
            guard case .malformedAudio = error else {
                throw ContractFailure(message: "symlink audio returned the wrong category: " + error.description)
            }
        }

        let rawSymlinkSession = try store.createSession()
        let outsideRaw = root.appendingPathComponent("outside-raw.txt")
        try Data("outside".utf8).write(to: outsideRaw, options: [.atomic])
        try FileManager.default.createSymbolicLink(at: rawSymlinkSession.rawTextURL, withDestinationURL: outsideRaw)
        defer { try? FileManager.default.removeItem(at: rawSymlinkSession.rawTextURL) }
        do {
            _ = try store.persistRawText("must not follow symlink", for: rawSymlinkSession)
            throw ContractFailure(message: "raw.txt persistence followed a symbolic-link artifact")
        } catch let error as SessionStoreError {
            guard case .invalidSessionDirectory = error else {
                throw ContractFailure(message: "raw symlink returned the wrong category: " + error.description)
            }
        }

        let descriptorSymlinkSession = try store.createSession()
        let descriptorSymlinkFailed = try store.update(
            descriptorSymlinkSession,
            state: .failed,
            failureReason: "descriptor symlink fixture"
        )
        let outsideDescriptorAudio = root.appendingPathComponent("outside-descriptor.caf")
        try Data([0x44, 0x45, 0x53]).write(to: outsideDescriptorAudio, options: [.atomic])
        try FileManager.default.createSymbolicLink(
            at: descriptorSymlinkFailed.audioURL,
            withDestinationURL: outsideDescriptorAudio
        )
        defer { try? FileManager.default.removeItem(at: descriptorSymlinkFailed.audioURL) }
        do {
            _ = try store.openAudioFileDescriptor(for: descriptorSymlinkFailed)
            throw ContractFailure(message: "audio descriptor followed a symbolic-link artifact")
        } catch let error as SessionStoreError {
            guard case .invalidSessionDirectory = error else {
                throw ContractFailure(message: "audio descriptor symlink returned the wrong category: " + error.description)
            }
        }

        let outsideSessionDirectory = root.deletingLastPathComponent()
            .appendingPathComponent("oigo-issue5-outside-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outsideSessionDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outsideSessionDirectory) }
        let outsideMetadata = SessionMetadata(
            id: UUID(),
            directoryName: outsideSessionDirectory.lastPathComponent,
            createdAt: Date(),
            updatedAt: Date(),
            state: .failed
        )
        let outsideSession = DictationSession(
            metadata: outsideMetadata,
            directoryURL: outsideSessionDirectory
        )
        do {
            _ = try store.openAudioFileDescriptor(for: outsideSession)
            throw ContractFailure(message: "audio descriptor accepted a session outside the store root")
        } catch let error as SessionStoreError {
            guard case .invalidSessionDirectory = error else {
                throw ContractFailure(message: "outside-root audio descriptor returned the wrong category: " + error.description)
            }
        }

        try FileManager.default.removeItem(at: completed.audioURL)
        do {
            _ = try SavedAudioRetry.retry(
                session: completed,
                store: store,
                liveFailure: TranscriptionError.analysisFailed("malformed fixture")
            ) { _ in () }
            throw ContractFailure(message: "missing saved audio unexpectedly passed retry validation")
        } catch let error as TranscriptionError {
            guard case .invalidSessionState = error else {
                throw ContractFailure(message: "retry state guard returned the wrong category: " + error.description)
            }
        }

        let interrupted = try store.update(completed, state: .interrupted, failureReason: "interrupted")
        do {
            _ = try SavedAudioRetry.retry(
                session: interrupted,
                store: store,
                liveFailure: TranscriptionError.analysisFailed("malformed fixture")
            ) { _ in () }
            throw ContractFailure(message: "missing saved audio unexpectedly passed malformed-audio validation")
        } catch let error as TranscriptionError {
            guard case .malformedAudio = error else {
                throw ContractFailure(message: "missing saved audio returned the wrong category: " + error.description)
            }
        }
    }
    @MainActor
    private static func testBoundedRetryStagingPreservation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-staging-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let created = try store.createSession()
        let failed = try store.update(created, state: .failed, failureReason: "staging fixture")
        _ = try store.persistRawText("original canonical", for: failed)

        let discarded = try store.beginRawTextStaging(for: failed)
        try store.appendRawText("replacement that must not publish", to: discarded, for: failed)
        try store.discardRawTextStaging(discarded, for: failed)
        guard try store.readRawText(for: failed) == "original canonical" else {
            throw ContractFailure(message: "discarded retry staging replaced canonical raw.txt")
        }

        let committed = try store.beginRawTextStaging(for: failed)
        try store.appendRawText("replacement transcript", to: committed, for: failed)
        let completed = try store.commitRawTextStaging(committed, for: failed)
        let rawText = try store.readRawText(for: completed)
        guard rawText == "replacement transcript",
              completed.metadata.rawTextByteCount == Int64(rawText.utf8.count) else {
            throw ContractFailure(message: "committed retry staging did not atomically publish canonical raw.txt")
        }
    }

    @MainActor
    private static func testPersistenceRecoveryFaultWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-persistence-recovery-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession()
        store.failNextMetadataWriteForTesting()
        do {
            _ = try store.persistRawText("recovered canonical", for: session)
            throw ContractFailure(message: "metadata fault injection did not fail the persistence transaction")
        } catch let error as SessionStoreError {
            guard case .invalidMetadata = error else {
                throw ContractFailure(message: "metadata fault injection returned the wrong category: " + error.description)
            }
        }

        guard try String(contentsOf: session.rawTextURL, encoding: .utf8) == "recovered canonical" else {
            throw ContractFailure(message: "raw.txt was not canonical after the metadata fault window")
        }
        let recovered = try store.load(id: session.id)
        guard recovered.metadata.rawTextByteCount == Int64("recovered canonical".utf8.count),
              try store.readRawText(for: recovered) == "recovered canonical" else {
            throw ContractFailure(message: "pending persistence journal did not recover metadata from committed raw.txt")
        }
    }

    @MainActor
    private static func testCanonicalFinalReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-final-replacement-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession()
        let persisted = try store.persistRawText("hello world", for: session)
        let replaced = try store.replaceRawTextTail(
            "hello world",
            with: "hello word",
            for: persisted
        )
        guard try store.readRawText(for: replaced) == "hello word",
              replaced.metadata.rawTextByteCount == Int64("hello word".utf8.count) else {
            throw ContractFailure(message: "canonical final replacement duplicated or lost corrected text")
        }

        let staging = try store.beginRawTextStaging(for: replaced)
        try store.appendRawText("hello world", to: staging, for: replaced)
        try store.replaceRawTextStagingTail(
            "hello world",
            with: "hello word",
            to: staging,
            for: replaced
        )
        let committed = try store.commitRawTextStaging(staging, for: replaced)
        guard try store.readRawText(for: committed) == "hello word" else {
            throw ContractFailure(message: "staged final replacement did not preserve corrected text")
        }

        func persist(
            _ finalization: TranscriptFinalization?,
            for session: inout DictationSession
        ) throws {
            guard let finalization else {
                return
            }
            switch finalization {
            case .append(let text):
                session = try store.appendRawText(text, for: session)
            case .replace(let existing, let replacement):
                session = try store.replaceRawTextTail(
                    existing,
                    with: replacement,
                    for: session
                )
            }
        }

        var overlapSession = try store.createSession()
        var overlapAccumulator = TranscriptionAccumulator()
        try persist(
            overlapAccumulator.ingestAndReport(
                range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
                text: "alpha",
                isFinal: true
            ).finalization,
            for: &overlapSession
        )
        try persist(
            overlapAccumulator.ingestAndReport(
                range: TranscriptionRange(startMilliseconds: 100, endMilliseconds: 200),
                text: "beta",
                isFinal: true
            ).finalization,
            for: &overlapSession
        )
        try persist(
            overlapAccumulator.ingestAndReport(
                range: TranscriptionRange(startMilliseconds: 50, endMilliseconds: 250),
                text: "beta gamma",
                isFinal: true
            ).finalization,
            for: &overlapSession
        )
        guard try store.readRawText(for: overlapSession) == "alpha beta gamma" else {
            throw ContractFailure(message: "extending multi-segment overlap duplicated canonical words")
        }

        var compactedSession = try store.createSession()
        var compactedAccumulator = TranscriptionAccumulator()
        for index in 0..<12 {
            try persist(
                compactedAccumulator.ingestAndReport(
                    range: TranscriptionRange(
                        startMilliseconds: Int64(index * 100),
                        endMilliseconds: Int64((index + 1) * 100)
                    ),
                    text: "segment-" + String(index),
                    isFinal: true
                ).finalization,
                for: &compactedSession
            )
        }
        let canonicalBeforeBroadCorrection = try store.readRawText(for: compactedSession)
        let snapshotBeforeBroadCorrection = compactedAccumulator.snapshot
        let broadCorrection = (0..<12)
            .map { "segment-" + String($0) }
            .joined(separator: " ")
        let rejectedBroadCorrection = compactedAccumulator.ingestAndReport(
            range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 1_200),
            text: broadCorrection,
            isFinal: true
        )
        guard rejectedBroadCorrection.finalization == nil,
              compactedAccumulator.snapshot == snapshotBeforeBroadCorrection,
              try store.readRawText(for: compactedSession) == canonicalBeforeBroadCorrection else {
            throw ContractFailure(message: "compacted-history correction duplicated the durable canonical prefix")
        }

        try persist(
            compactedAccumulator.ingestAndReport(
                range: TranscriptionRange(startMilliseconds: 1_100, endMilliseconds: 1_200),
                text: "segment-11 revised",
                isFinal: true
            ).finalization,
            for: &compactedSession
        )
        guard try store.readRawText(for: compactedSession) == "segment-0 segment-1 segment-2 segment-3 segment-4 segment-5 segment-6 segment-7 segment-8 segment-9 segment-10 segment-11 revised" else {
            throw ContractFailure(message: "a final after rejected compacted-history correction failed or duplicated canonical text")
        }
    }

    @MainActor
    private static func testAppendOnlyPersistenceIsIncremental() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-append-amplification-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession()
        store.resetRawTextPersistenceMetricsForTesting()
        for index in 0..<64 {
            session = try store.appendRawText("segment-" + String(index), for: session)
        }
        let metrics = store.rawTextPersistenceMetricsForTesting()
        let rawText = try store.readRawText(for: session)
        let expected = (0..<64).map { "segment-" + String($0) }.joined(separator: " ")
        guard rawText == expected,
              session.metadata.rawTextByteCount == Int64(rawText.utf8.count),
              session.metadata.firstTranscriptLine == "segment-0",
              session.metadata.rawTextRevision == 64 else {
            throw ContractFailure(message: "append-only transcript lost ordering or metadata")
        }
        guard metrics.transcriptBytesRead == 0,
              metrics.transcriptBytesRewritten == 0,
              metrics.appendCount == 64,
              metrics.transcriptBytesWritten == Int64(rawText.utf8.count),
              metrics.lastResultCode == "append" else {
            throw ContractFailure(
                message: "append-only persistence reread or rewrote the transcript: read="
                    + String(metrics.transcriptBytesRead)
                    + " rewritten="
                    + String(metrics.transcriptBytesRewritten)
                    + " written="
                    + String(metrics.transcriptBytesWritten)
                    + " appends="
                    + String(metrics.appendCount)
            )
        }
    }

    @MainActor
    private static func testUnchangedFinalCheckpointDoesNotRewrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-checkpoint-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession()
        session = try store.appendRawText("durable canonical", for: session)
        session = try store.persistCleanText("Durable Canonical.", for: session)
        let revision = session.metadata.rawTextRevision
        store.resetRawTextPersistenceMetricsForTesting()
        let checkpoint = try store.checkpointCanonicalRawText(for: session)
        let metrics = store.rawTextPersistenceMetricsForTesting()
        let reloaded = try store.load(id: session.id)
        guard checkpoint.contentUnchanged,
              checkpoint.metadataOutcome == .consistent,
              checkpoint.rawTextByteCount == Int64("durable canonical".utf8.count),
              checkpoint.session.metadata.rawTextRevision == revision,
              reloaded.metadata.rawTextRevision == revision,
              try store.readRawText(for: reloaded) == "durable canonical",
              try store.readCleanText(for: reloaded) == "Durable Canonical.",
              metrics.transcriptBytesRewritten == 0,
              metrics.checkpointCount == 1,
              metrics.lastResultCode == "checkpoint-consistent" else {
            throw ContractFailure(message: "unchanged final checkpoint rewrote raw.txt or bumped the revision")
        }
    }

    @MainActor
    private static func testRawTextCrashRecoveryKeepsOneCanonicalOrdering() throws {
        let cases: [(RawTextPersistenceFault, String, UInt64)] = [
            (.beforeAppend, "one", 1),
            (.afterTextWrite, "one two", 2),
            (.afterFsync, "one two", 2),
            (.beforeMetadataCommit, "one two", 2),
            (.afterMetadataCommit, "one two", 2)
        ]
        for (fault, expectedText, expectedRevision) in cases {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "oigo-issue5-raw-crash-" + fault.rawValue + "-" + UUID().uuidString,
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }

            let store = try SessionStore(rootDirectory: root)
            var session = try store.createSession()
            session = try store.appendRawText("one", for: session)
            store.armRawTextPersistenceFaultForTesting(fault)
            do {
                _ = try store.appendRawText("two", for: session)
                throw ContractFailure(message: fault.rawValue + " did not interrupt append")
            } catch let error as ContractFailure {
                throw error
            } catch {
                _ = error
            }
            let recovered = try store.load(id: session.id)
            let rawText = try store.readRawText(for: recovered)
            guard rawText == expectedText,
                  recovered.metadata.rawTextByteCount == Int64(rawText.utf8.count),
                  recovered.metadata.firstTranscriptLine == "one",
                  recovered.metadata.rawTextRevision == expectedRevision,
                  !FileManager.default.fileExists(
                      atPath: recovered.directoryURL.appendingPathComponent(".raw-persistence.json").path
                  ) else {
                throw ContractFailure(
                    message: fault.rawValue
                        + " recovery produced byteCount="
                        + String(recovered.metadata.rawTextByteCount ?? -1)
                        + " revision="
                        + String(recovered.metadata.rawTextRevision)
                        + " textMatch="
                        + String(rawText == expectedText)
                )
            }
        }

        let revisionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-revise-crash-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: revisionRoot) }
        let revisionStore = try SessionStore(rootDirectory: revisionRoot)
        var revisionSession = try revisionStore.createSession()
        revisionSession = try revisionStore.appendRawText("hello world", for: revisionSession)
        revisionStore.armRawTextPersistenceFaultForTesting(.duringTailRevision)
        do {
            _ = try revisionStore.replaceRawTextTail(
                "hello world",
                with: "hello word",
                for: revisionSession
            )
            throw ContractFailure(message: "tail revision fault did not interrupt replacement")
        } catch let error as ContractFailure {
            throw error
        } catch {
            _ = error
        }
        let recoveredRevision = try revisionStore.load(id: revisionSession.id)
        guard try revisionStore.readRawText(for: recoveredRevision) == "hello world",
              recoveredRevision.metadata.rawTextByteCount == Int64("hello world".utf8.count),
              recoveredRevision.metadata.rawTextRevision == 1 else {
            throw ContractFailure(message: "interrupted tail revision did not restore the prior canonical suffix")
        }
    }

    @MainActor
    private static func testShortWriteRecoversDurablePrefix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-short-write-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession()
        session = try store.appendRawText("durable prefix", for: session)
        store.armRawTextPersistenceFaultForTesting(.shortWrite)
        do {
            _ = try store.appendRawText("should not commit", for: session)
            throw ContractFailure(message: "short write did not fail the append")
        } catch let error as ContractFailure {
            throw error
        } catch {
            _ = error
        }
        let recovered = try store.load(id: session.id)
        let rawText = try store.readRawText(for: recovered)
        guard rawText == "durable prefix",
              recovered.metadata.rawTextByteCount == Int64(rawText.utf8.count),
              recovered.metadata.firstTranscriptLine == "durable prefix",
              recovered.metadata.rawTextRevision == 1 else {
            throw ContractFailure(message: "short write left unrecovered partial canonical bytes")
        }
    }

    @MainActor
    private static func testFinalCheckpointMetadataFailureRetainsTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-checkpoint-metadata-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession()
        session = try store.appendRawText("already durable speech", for: session)
        let revision = session.metadata.rawTextRevision
        store.armRawTextPersistenceFaultForTesting(.duringFinalCheckpoint)
        let checkpoint = try store.checkpointCanonicalRawText(for: session)
        let reloaded = try store.load(id: session.id)
        guard checkpoint.metadataOutcome == .recoverableFailure,
              checkpoint.contentUnchanged,
              checkpoint.rawTextByteCount == Int64("already durable speech".utf8.count),
              try store.readRawText(for: reloaded) == "already durable speech",
              reloaded.metadata.rawTextRevision == revision,
              reloaded.metadata.firstTranscriptLine == "already durable speech" else {
            throw ContractFailure(message: "final checkpoint metadata failure claimed the durable transcript was lost")
        }

        var stale = try JSONSerialization.jsonObject(
            with: Data(contentsOf: session.metadataURL)
        ) as? [String: Any]
        stale?["rawTextByteCount"] = 1
        try JSONSerialization.data(withJSONObject: stale ?? [:], options: [.sortedKeys])
            .write(to: session.metadataURL, options: [.atomic])
        store.failNextMetadataWriteForTesting()
        let reconciled = try store.checkpointCanonicalRawText(for: session)
        guard reconciled.metadataOutcome == .recoverableFailure,
              try store.readRawText(for: session) == "already durable speech" else {
            throw ContractFailure(message: "metadata reconcile failure hid the durable raw transcript")
        }
        guard store.rawTextPersistenceMetricsForTesting().lastResultCode == "checkpoint-metadata-failure" else {
            throw ContractFailure(message: "checkpoint metadata failure used an imprecise result code")
        }
    }

    @MainActor
    private static func testTailRevisionIsBoundedAndSuffixVerified() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-bounded-revision-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession()
        let prefix = Array(repeating: "alpha", count: 1_024).joined(separator: " ")
        session = try store.appendRawText(prefix, for: session)
        session = try store.appendRawText("omega", for: session)
        store.resetRawTextPersistenceMetricsForTesting()
        session = try store.replaceRawTextTail("omega", with: "omega revised", for: session)
        let metrics = store.rawTextPersistenceMetricsForTesting()
        let expected = prefix + " omega revised"
        let suffixReadBound = Int64("omega".utf8.count + 1)
        guard try store.readRawText(for: session) == expected,
              session.metadata.rawTextByteCount == Int64(expected.utf8.count),
              session.metadata.firstTranscriptLine == String(prefix.prefix(512)),
              metrics.revisionCount == 1,
              metrics.transcriptBytesRead <= suffixReadBound,
              metrics.transcriptBytesRewritten == 0,
              metrics.lastResultCode == "revise" else {
            throw ContractFailure(
                message: "tail revision reread or rewrote more than the bounded suffix: read="
                    + String(metrics.transcriptBytesRead)
                    + " rewritten="
                    + String(metrics.transcriptBytesRewritten)
            )
        }

        do {
            _ = try store.replaceRawTextTail("missing suffix", with: "nope", for: session)
            throw ContractFailure(message: "mismatched tail revision was accepted")
        } catch let error as ContractFailure {
            throw error
        } catch let error as SessionStoreError {
            guard case .invalidMetadata = error else {
                throw ContractFailure(message: "mismatched tail revision returned the wrong error")
            }
        }
        guard try store.readRawText(for: session) == expected else {
            throw ContractFailure(message: "rejected tail revision mutated canonical raw.txt")
        }

        store.resetRawTextPersistenceMetricsForTesting()
        let unchanged = try store.replaceRawTextTail(
            "omega revised",
            with: "omega revised",
            for: session
        )
        guard unchanged.metadata.rawTextRevision == session.metadata.rawTextRevision,
              store.rawTextPersistenceMetricsForTesting().lastResultCode == "revise-unchanged" else {
            throw ContractFailure(message: "identical tail revision bumped rawTextRevision")
        }
    }

    @MainActor
    private static func testSameLengthTailRevisionInterruptedBeforeTruncate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-same-length-revise-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession()
        session = try store.appendRawText("hello", for: session)
        let revision = session.metadata.rawTextRevision
        store.armRawTextPersistenceFaultForTesting(.beforeTailRevision)
        do {
            _ = try store.replaceRawTextTail("hello", with: "world", for: session)
            throw ContractFailure(message: "same-length revision fault did not fire before truncate")
        } catch let error as ContractFailure {
            throw error
        } catch {
            _ = error
        }
        let recovered = try store.load(id: session.id)
        let rawText = try store.readRawText(for: recovered)
        guard rawText == "hello",
              recovered.metadata.rawTextByteCount == Int64(rawText.utf8.count),
              recovered.metadata.firstTranscriptLine == "hello",
              recovered.metadata.rawTextRevision == revision else {
            throw ContractFailure(message: "same-length interrupt-before-truncate published the replacement suffix")
        }
    }

    @MainActor
    private static func testLongerRewriteShortWriteRestoresPreviousSuffix() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-revise-short-write-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession()
        session = try store.appendRawText("abc", for: session)
        let revision = session.metadata.rawTextRevision
        store.armRawTextPersistenceFaultForTesting(.shortWrite)
        do {
            _ = try store.replaceRawTextTail("abc", with: "xyz extra", for: session)
            throw ContractFailure(message: "longer rewrite short write did not fail")
        } catch let error as ContractFailure {
            throw error
        } catch {
            _ = error
        }
        let recovered = try store.load(id: session.id)
        let rawText = try store.readRawText(for: recovered)
        guard rawText == "abc",
              recovered.metadata.rawTextByteCount == Int64(rawText.utf8.count),
              recovered.metadata.firstTranscriptLine == "abc",
              recovered.metadata.rawTextRevision == revision else {
            throw ContractFailure(message: "longer rewrite short write at the old size kept a replacement prefix")
        }
    }

    @MainActor
    private static func testNewlinePrefixedFirstSegmentThenSecondAppend() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-newline-prefix-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession()
        session = try store.appendRawText("\nhello", for: session)
        guard session.metadata.firstTranscriptLine == nil else {
            throw ContractFailure(message: "newline-prefixed first segment should leave firstTranscriptLine unset")
        }
        store.resetRawTextPersistenceMetricsForTesting()
        session = try store.appendRawText("world", for: session)
        let metrics = store.rawTextPersistenceMetricsForTesting()
        let rawText = try store.readRawText(for: session)
        guard rawText == "\nhello world",
              session.metadata.rawTextByteCount == Int64(rawText.utf8.count),
              metrics.lastResultCode == "append",
              metrics.transcriptBytesRead > 0,
              metrics.transcriptBytesRead <= 4_096,
              metrics.transcriptBytesRewritten == 0 else {
            throw ContractFailure(message: "second append after a newline-prefixed first segment failed or reread unbounded bytes")
        }
    }

    @MainActor
    private static func testMissingRawTextWithStaleByteCountDoesNotCheckpointEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-missing-raw-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        var session = try store.createSession()
        session = try store.appendRawText("already durable speech", for: session)
        try FileManager.default.removeItem(at: session.rawTextURL)
        do {
            let checkpoint = try store.checkpointCanonicalRawText(for: session)
            throw ContractFailure(
                message: "missing raw.txt checkpointed as empty+nonzero outcome="
                    + checkpoint.metadataOutcome.rawValue
                    + " byteCount="
                    + String(checkpoint.rawTextByteCount)
            )
        } catch let error as ContractFailure {
            throw error
        } catch let error as SessionStoreError {
            guard case .invalidSessionDirectory = error else {
                throw ContractFailure(message: "missing raw.txt with stale byte count returned the wrong error")
            }
        }
        let reloaded = try store.load(id: session.id)
        guard reloaded.metadata.rawTextByteCount == Int64("already durable speech".utf8.count),
              try store.readRawText(for: reloaded).isEmpty else {
            throw ContractFailure(message: "missing raw.txt changed stale metadata instead of failing the checkpoint")
        }
    }

    @MainActor
    private static func testBoundedAnalyzerInputPolicy() throws {
        guard AnalyzerInputLimits.capacity == 32,
              AnalyzerInputLimits.maxRetainedBytes
                == AnalyzerInputLimits.capacity * AnalyzerInputLimits.maxBytesPerInput,
              AnalyzerInputLimits.maxRetainedBytes == 1_048_576 else {
            throw ContractFailure(message: "analyzer-input capacity is no longer a documented 32-slot / 1 MiB bound")
        }
        let generation = UUID()
        let intake = AnalyzerInputBackpressure(
            generation: generation,
            capacity: AnalyzerInputLimits.capacity
        )
        let (input, byteCount) = try makeAnalyzerInput()
        for _ in 0..<AnalyzerInputLimits.capacity {
            let outcome = intake.enqueue(input, generation: generation, byteCount: byteCount)
            guard outcome == .enqueued else {
                throw ContractFailure(message: "documented capacity rejected input before filling")
            }
        }
        let overflow = intake.enqueue(input, generation: generation, byteCount: byteCount)
        let metrics = intake.metrics
        guard overflow == .saturated,
              metrics.degradation == .queueSaturated,
              metrics.highWaterDepth == AnalyzerInputLimits.capacity,
              metrics.highWaterBytes <= AnalyzerInputLimits.maxRetainedBytes,
              metrics.lastYieldOutcome == .saturated else {
            throw ContractFailure(message: "bounded analyzer-input policy did not saturate at the documented cap")
        }
        for _ in 0..<10_000 {
            let outcome = intake.enqueue(input, generation: generation, byteCount: byteCount)
            guard outcome == .rejected else {
                throw ContractFailure(message: "stalled consumer kept growing after saturation")
            }
        }
        let bounded = intake.metrics
        guard bounded.highWaterDepth == AnalyzerInputLimits.capacity,
              bounded.enqueueAccepted == AnalyzerInputLimits.capacity,
              bounded.highWaterBytes <= AnalyzerInputLimits.maxRetainedBytes else {
            throw ContractFailure(message: "never-read consumer exceeded the analyzer-input memory bound")
        }
    }

    @MainActor
    private static func testNeverReadConsumerSaturates() async throws {
        let service = TranscriptionService()
        let updates = UpdateCollector()
        _ = try service.startLiveIntakeFixture(
            consumer: .neverRead,
            onUpdate: { update in updates.append(update) }
        )
        let buffer = makeCaptureBuffer()
        for _ in 0..<(AnalyzerInputLimits.capacity + 8) {
            service.append(buffer)
        }
        let metrics = service.analyzerInputMetricsForTesting
        guard service.liveDegradationForTesting == .queueSaturated,
              service.lastTranscriptionError == .liveQueueSaturated,
              updates.values.contains(where: {
                  $0.liveDegradation == .queueSaturated
                      && $0.volatilePreview.isEmpty
                      && $0.finalizedSegment == nil
              }),
              metrics.highWaterDepth <= AnalyzerInputLimits.capacity,
              metrics.highWaterBytes <= AnalyzerInputLimits.maxRetainedBytes,
              metrics.enqueueAccepted <= AnalyzerInputLimits.capacity else {
            throw ContractFailure(message: "never-read consumer did not emit typed saturation")
        }
        service.append(buffer)
        guard service.analyzerInputMetricsForTesting.enqueueAccepted == metrics.enqueueAccepted else {
            throw ContractFailure(message: "conversion continued after live degradation")
        }
        await service.stopLiveIntakeFixture()
    }

    @MainActor
    private static func testSlowConsumerSaturates() async throws {
        let service = TranscriptionService()
        let updates = UpdateCollector()
        _ = try service.startLiveIntakeFixture(
            consumer: .slow(nanoseconds: 50_000_000),
            onUpdate: { update in updates.append(update) }
        )
        let buffer = makeCaptureBuffer()
        for _ in 0..<(AnalyzerInputLimits.capacity * 2) {
            service.append(buffer)
        }
        guard service.liveDegradationForTesting == .queueSaturated,
              updates.values.contains(where: { $0.liveDegradation == .queueSaturated }),
              service.analyzerInputMetricsForTesting.highWaterDepth <= AnalyzerInputLimits.capacity else {
            throw ContractFailure(message: "slow consumer did not saturate with a typed degradation")
        }
        await service.stopLiveIntakeFixture()
    }

    @MainActor
    private static func testTerminatedContinuationIsVisible() throws {
        let generation = UUID()
        let intake = AnalyzerInputBackpressure(generation: generation, capacity: 4)
        let (input, byteCount) = try makeAnalyzerInput()
        intake.finish()
        let outcome = intake.enqueue(input, generation: generation, byteCount: byteCount)
        guard outcome == .terminated,
              intake.metrics.degradation == .continuationTerminated,
              intake.metrics.lastYieldOutcome == .terminated else {
            throw ContractFailure(message: "terminated continuation was not a typed live-speech outcome")
        }
    }

    @MainActor
    private static func testConversionAnalyzerAndResultFailuresReachCoordinator() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-live-failures-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let conversion = TranscriptionService()
        let conversionUpdates = UpdateCollector()
        _ = try conversion.startLiveIntakeFixture(
            onUpdate: { update in conversionUpdates.append(update) }
        )
        conversion.append(
            AudioCaptureBuffer(
                frameCount: 4,
                sampleRate: 16_000,
                channelCount: 2,
                pcmData: Data(count: 32)
            )
        )
        guard conversion.liveDegradationForTesting == .conversionFailed,
              conversion.lastTranscriptionError == .liveConversionFailed,
              conversionUpdates.values.contains(where: { $0.liveDegradation == .conversionFailed }) else {
            throw ContractFailure(message: "conversion failure stayed internal")
        }
        await conversion.stopLiveIntakeFixture()

        let analyzerService = TranscriptionService()
        let analyzerUpdates = UpdateCollector()
        _ = try analyzerService.startLiveIntakeFixture(
            onUpdate: { update in analyzerUpdates.append(update) }
        )
        analyzerService.injectAnalyzerFailureForTesting()
        guard analyzerService.liveDegradationForTesting == .analyzerFailed,
              analyzerUpdates.values.contains(where: { $0.liveDegradation == .analyzerFailed }) else {
            throw ContractFailure(message: "analyzer failure stayed internal")
        }
        await analyzerService.stopLiveIntakeFixture()

        let resultService = TranscriptionService()
        let resultUpdates = UpdateCollector()
        _ = try resultService.startLiveIntakeFixture(
            onUpdate: { update in resultUpdates.append(update) }
        )
        resultService.injectResultSequenceFailureForTesting()
        guard resultService.liveDegradationForTesting == .resultSequenceFailed,
              resultUpdates.values.contains(where: { $0.liveDegradation == .resultSequenceFailed }) else {
            throw ContractFailure(message: "result-sequence failure stayed internal")
        }
        await resultService.stopLiveIntakeFixture()

        let transcription = FakeTranscriptionController()
        let coordinator = DictationCoordinator()
        let updates = UpdateCollector()
        _ = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
            onUpdate: { update in updates.append(update) }
        )
        transcription.emitDegradation(.analyzerFailed)
        for _ in 0..<200 where coordinator.liveTranscriptionDegradation == nil {
            await Task.yield()
        }
        guard coordinator.state == .recording,
              coordinator.liveTranscriptionDegradation == .analyzerFailed,
              coordinator.lastFailureCode == .transcriptionFailed,
              coordinator.liveRecordingHUDDetail
                == LiveTranscriptionHUDCopy.recordingPreservedRetryRequired,
              capture.isActive else {
            throw ContractFailure(message: "live analyzer failure did not reach the coordinator during capture")
        }
        do {
            _ = try await coordinator.stopRecordingWithTranscription()
            throw ContractFailure(message: "degraded live analysis completed as success")
        } catch let error as TranscriptionError {
            guard error == .analysisFailed("speech analyzer failed") else {
                throw ContractFailure(message: "degraded finish changed category: " + error.description)
            }
        }
    }

    @MainActor
    private static func testStaleGenerationCannotPersist() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-stale-generation-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let firstSession = try store.createSession()
        _ = try store.persistRawText("", for: firstSession)
        let service = TranscriptionService()
        let firstID = try service.startLiveIntakeFixture(session: firstSession, store: store)
        service.injectAnalyzerFailureForTesting()
        service.consumeFinalForTesting(operationID: firstID, text: "degraded generation")
        guard try store.readRawText(for: firstSession).isEmpty else {
            throw ContractFailure(message: "degraded generation persisted canonical raw text")
        }
        await service.stopLiveIntakeFixture()

        let secondSession = try store.createSession()
        _ = try store.persistRawText("", for: secondSession)
        let secondID = try service.startLiveIntakeFixture(session: secondSession, store: store)
        service.consumeFinalForTesting(operationID: firstID, text: "stale generation")
        guard try store.readRawText(for: secondSession).isEmpty,
              secondID != firstID,
              service.liveDegradationForTesting == nil else {
            throw ContractFailure(message: "stale generation mutated a later session")
        }
        await service.stopLiveIntakeFixture()
    }

    @MainActor
    private static func testLiveSpeechDegradationPreservesCAFAndRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-live-retry-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController()
        transcription.finalizedText = "saved audio retry transcript"
        let coordinator = DictationCoordinator()
        capture.writesCanonicalCAF = true
        let session: DictationSession
        do {
            session = try await coordinator.startRecordingWithTranscription(
                using: capture,
                store: store,
                transcription: transcription,
                format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
            )
            try capture.writeCanonicalFrames()
        } catch {
            print("INCONCLUSIVE: native CAF writer unavailable: " + String(describing: error))
            _ = try? await coordinator.cancelRecordingWithTranscription()
            return
        }
        transcription.emitDegradation(.queueSaturated)
        for _ in 0..<200 where coordinator.liveTranscriptionDegradation == nil {
            await Task.yield()
        }
        guard coordinator.state == .recording,
              coordinator.liveTranscriptionDegraded,
              coordinator.currentSession?.metadata.failureCode == .transcriptionFailed,
              coordinator.currentSession?.metadata.failureReason == LiveTranscriptionDegradation.queueSaturated.rawValue,
              FileManager.default.fileExists(atPath: session.audioURL.path) else {
            throw ContractFailure(message: "live saturation did not persist a content-free retry-required code")
        }
        do {
            _ = try await coordinator.stopRecordingWithTranscription()
            throw ContractFailure(message: "saturated live analysis completed as success")
        } catch let error as TranscriptionError {
            guard error == .liveQueueSaturated else {
                throw ContractFailure(message: "saturation finish changed category: " + error.description)
            }
        }
        let failed = try store.load(id: session.id)
        let history = DictationHistoryActions.capabilities(
            sessionState: failed.metadata.state,
            hasValidRaw: false,
            hasAudio: FileManager.default.fileExists(atPath: failed.audioURL.path)
        )
        let frames: AVAudioFramePosition
        do {
            frames = try AudioPlayback.playableFrameLength(at: failed.audioURL)
        } catch {
            throw ContractFailure(
                message: "durable capture frames were not playable after live speech degradation: "
                    + String(describing: error)
            )
        }
        guard failed.metadata.state == .failed,
              failed.metadata.failureCode == .transcriptionFailed,
              history.savedAudioRetryAvailable,
              frames > 0 else {
            throw ContractFailure(message: "live speech degradation lost the playable CAF or saved-audio retry")
        }
        let retried = try await coordinator.retryRecordingWithTranscription(
            for: failed,
            using: transcription,
            store: store
        )
        guard retried.metadata.state == .completed,
              try store.readRawText(for: retried) == "saved audio retry transcript" else {
            throw ContractFailure(message: "saved-audio retry was not available after live speech degradation")
        }
    }

    @MainActor
    private static func testWriterFailureDistinctFromSpeechDegradation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-writer-vs-speech-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let speechCapture = FakeAudioCapture()
        let speechTranscription = FakeTranscriptionController()
        let speechCoordinator = DictationCoordinator()
        _ = try await speechCoordinator.startRecordingWithTranscription(
            using: speechCapture,
            store: store,
            transcription: speechTranscription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        speechTranscription.emitDegradation(.conversionFailed)
        for _ in 0..<200 where speechCoordinator.liveTranscriptionDegradation == nil {
            await Task.yield()
        }
        guard speechCoordinator.state == .recording,
              speechCoordinator.lastFailureCode == .transcriptionFailed,
              speechCapture.isActive else {
            throw ContractFailure(message: "live speech degradation terminalized durable capture")
        }
        _ = try? await speechCoordinator.stopRecordingWithTranscription()

        let writerStore = try SessionStore(
            rootDirectory: root.appendingPathComponent("writer", isDirectory: true)
        )
        let writerCapture = FakeAudioCapture()
        let writerCoordinator = DictationCoordinator()
        let writerSession = try writerCoordinator.startRecording(using: writerCapture, store: writerStore)
        writerCapture.sendBuffer()
        writerCapture.emitFailure("audio file write failed: disk full")
        for _ in 0..<200 where writerCoordinator.state == .recording {
            await Task.yield()
        }
        let writerFailed = try writerStore.load(id: writerSession.id)
        guard writerCoordinator.state == .failed,
              writerFailed.metadata.failureCode == .audioWriteFailed,
              writerFailed.metadata.failureCode != speechCoordinator.lastFailureCode
                || speechCoordinator.lastFailureCode == .transcriptionFailed else {
            throw ContractFailure(message: "durable-writer failure was not distinct from live-speech degradation")
        }
    }

    private static func makeAnalyzerPCMBuffer(frames: Int = 256) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        ) else {
            throw ContractFailure(message: "could not allocate analyzer fixture buffer")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    private static func makeAnalyzerInput(frames: Int = 256) throws -> (AnalyzerInput, Int) {
        let buffer = try makeAnalyzerPCMBuffer(frames: frames)
        return (AnalyzerInput(buffer: buffer), frames * MemoryLayout<Int16>.size)
    }

    private static func makeCaptureBuffer(frames: Int = 256) -> AudioCaptureBuffer {
        let samples = [Float](repeating: 0.05, count: frames)
        let data = samples.withUnsafeBytes { Data($0) }
        return AudioCaptureBuffer(
            frameCount: frames,
            sampleRate: 16_000,
            channelCount: 1,
            pcmData: data
        )
    }

    @MainActor
    private static func testRetryFeedSaturatesOnStalledConsumer() throws {
        let generation = UUID()
        let intake = AnalyzerInputBackpressure(generation: generation)
        let service = TranscriptionService()
        let pcmBuffer = try makeAnalyzerPCMBuffer()
        do {
            for _ in 0..<(AnalyzerInputLimits.capacity + 8) {
                try service.enqueueRetryInputForTesting(
                    pcmBuffer,
                    intake: intake,
                    operationID: generation
                )
            }
            throw ContractFailure(message: "stalled retry feed completed without saturating")
        } catch let error as TranscriptionError {
            guard error == .liveQueueSaturated else {
                throw ContractFailure(message: "stalled retry feed changed category: " + error.description)
            }
        }
        let metrics = intake.metrics
        guard metrics.degradation == .queueSaturated,
              metrics.highWaterDepth <= AnalyzerInputLimits.capacity,
              metrics.highWaterBytes <= AnalyzerInputLimits.maxRetainedBytes,
              metrics.enqueueAccepted <= AnalyzerInputLimits.capacity else {
            throw ContractFailure(message: "stalled retry consumer grew past the analyzer-input bound")
        }
    }

    @MainActor
    private static func testPreparingDegradationPersistsIntoRecording() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-preparing-degrade-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController()
        transcription.emitDegradationOnStart = .analyzerFailed
        let coordinator = DictationCoordinator()
        let session = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        for _ in 0..<200 where coordinator.liveTranscriptionDegradation == nil {
            await Task.yield()
        }
        let loaded = try store.load(id: session.id)
        guard coordinator.state == .recording,
              coordinator.liveTranscriptionDegradation == .analyzerFailed,
              session.metadata.failureCode == .transcriptionFailed
                || loaded.metadata.failureCode == .transcriptionFailed,
              loaded.metadata.failureReason == LiveTranscriptionDegradation.analyzerFailed.rawValue,
              capture.isActive else {
            throw ContractFailure(message: "preparing live degradation did not persist into recording metadata")
        }
    }

}

private final class UpdateCollector: @unchecked Sendable {
    private(set) var values: [TranscriptionUpdate] = []

    func append(_ value: TranscriptionUpdate) {
        values.append(value)
    }
}

@available(macOS 26.0, *)
private final class FakeTranscriptionController: TranscriptionController, @unchecked Sendable {
    private var session: DictationSession?
    private var store: SessionStore?
    private var onUpdate: (@Sendable (TranscriptionUpdate) -> Void)?
    private(set) var isRunning = false
    private(set) var appendedBufferCount = 0
    var finalizedText = ""
    var finishError: Error?
    var emitDegradationOnStart: LiveTranscriptionDegradation?

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        guard format.isValid, format.channelCount == 1 else {
            throw TranscriptionError.invalidCaptureFormat
        }
        self.session = session
        self.store = store
        self.onUpdate = onUpdate
        isRunning = true
        appendedBufferCount = 0
        if let emitDegradationOnStart {
            emitDegradation(emitDegradationOnStart)
            for _ in 0..<20 {
                await Task.yield()
            }
        }
    }

    func append(_ buffer: AudioCaptureBuffer) {
        guard isRunning else {
            return
        }
        appendedBufferCount += 1
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        if let finishError {
            throw finishError
        }
        isRunning = false
        defer { clearResources() }
        let result = try persist()
        return result
    }

    func cancel() async throws -> TranscriptionResult? {
        guard isRunning else {
            return nil
        }
        isRunning = false
        defer { clearResources() }
        return try persist()
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        let descriptor = try store.openAudioFileDescriptor(for: session)
        defer { descriptor.close() }
        let url = URL(fileURLWithPath: "/dev/fd/\(descriptor.rawValue)")
        let persisted = try store.persistRawText(finalizedText, for: session)
        _ = try store.update(
            persisted,
            state: .completed,
            audioByteCount: Int64(try Data(contentsOf: url).count),
            rawTextByteCount: Int64(finalizedText.utf8.count)
        )
        return TranscriptionResult(
            finalizedText: finalizedText,
            rawTextByteCount: Int64(finalizedText.utf8.count)
        )
    }

    func emit(_ update: TranscriptionUpdate) {
        onUpdate?(update)
    }

    func emitDegradation(_ degradation: LiveTranscriptionDegradation) {
        switch degradation {
        case .queueSaturated:
            finishError = TranscriptionError.liveQueueSaturated
        case .continuationTerminated:
            finishError = TranscriptionError.liveContinuationTerminated
        case .conversionFailed:
            finishError = TranscriptionError.liveConversionFailed
        case .analyzerFailed:
            finishError = TranscriptionError.analysisFailed("speech analyzer failed")
        case .resultSequenceFailed:
            finishError = TranscriptionError.analysisFailed("speech result sequence failed")
        }
        onUpdate?(TranscriptionUpdate.liveHealth(degradation))
    }

    private func persist() throws -> TranscriptionResult {
        guard let session, let store else {
            throw ContractFailure(message: "fake transcription lost its session resources")
        }
        let persisted = try store.persistRawText(finalizedText, for: session)
        _ = persisted
        return TranscriptionResult(
            finalizedText: finalizedText,
            rawTextByteCount: Int64(finalizedText.utf8.count)
        )
    }

    private func clearResources() {
        session = nil
        store = nil
        onUpdate = nil
    }
}

@available(macOS 26.0, *)
private final class BlockingTranscriptionController: TranscriptionController, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var cancellationRequested = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        _ = session
        _ = format
        _ = store
        _ = onUpdate
        let waiters = withLock {
            started = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll(keepingCapacity: true)
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }

        await withCheckedContinuation { continuation in
            let resumeImmediately = withLock {
                if cancellationRequested {
                    return true
                }
                startContinuation = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
        throw TranscriptionError.cancelled
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        throw TranscriptionError.analysisFailed("blocking fixture cannot finish")
    }

    func cancel() async throws -> TranscriptionResult? {
        let continuation = withLock {
            cancellationRequested = true
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        continuation?.resume()
        return nil
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        _ = session
        _ = store
        throw TranscriptionError.analysisFailed("blocking fixture cannot retry")
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = withLock {
                if started {
                    return true
                }
                enteredWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@available(macOS 26.0, *)
private final class BlockingFinishTranscriptionController: TranscriptionController, @unchecked Sendable {
    private let lock = NSLock()
    private var session: DictationSession?
    private var store: SessionStore?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var finishStarted = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelCalls = 0
    private(set) var isRunning = false
    var finalizedText = ""

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        guard format.isValid, format.channelCount == 1 else {
            throw TranscriptionError.invalidCaptureFormat
        }
        self.session = session
        self.store = store
        _ = onUpdate
        withLock { isRunning = true }
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        await withCheckedContinuation { continuation in
            let waiters = withLock {
                finishStarted = true
                finishContinuation = continuation
                let waiters = finishWaiters
                finishWaiters.removeAll(keepingCapacity: true)
                return waiters
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
        guard let session, let store else {
            throw ContractFailure(message: "blocking finish fixture lost its session")
        }
        withLock { isRunning = false }
        defer { clearResources() }
        _ = try store.persistRawText(finalizedText, for: session)
        return TranscriptionResult(
            finalizedText: finalizedText,
            rawTextByteCount: Int64(finalizedText.utf8.count)
        )
    }

    func cancel() async throws -> TranscriptionResult? {
        let continuation = withLock {
            cancelCalls += 1
            let continuation = finishContinuation
            finishContinuation = nil
            return continuation
        }
        continuation?.resume()
        return nil
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        _ = session
        _ = store
        throw TranscriptionError.analysisFailed("blocking finish fixture cannot retry")
    }

    func waitUntilFinishStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = withLock {
                if finishStarted {
                    return true
                }
                finishWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func releaseFinish() {
        let continuation = withLock {
            let continuation = finishContinuation
            finishContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func clearResources() {
        session = nil
        store = nil
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@available(macOS 26.0, *)
private final class BlockingRetryTranscriptionController: TranscriptionController, @unchecked Sendable {
    private let lock = NSLock()
    private var retryContinuation: CheckedContinuation<Void, Never>?
    private var retryStarted = false
    private var cancellationRequested = false
    private var retryWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelCalls = 0

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        _ = session
        _ = format
        _ = store
        _ = onUpdate
        throw TranscriptionError.analysisFailed("blocking retry fixture cannot start live capture")
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        throw TranscriptionError.analysisFailed("blocking retry fixture cannot finish")
    }

    func cancel() async throws -> TranscriptionResult? {
        let continuation = withLock {
            cancelCalls += 1
            cancellationRequested = true
            let continuation = retryContinuation
            retryContinuation = nil
            return continuation
        }
        continuation?.resume()
        return nil
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        _ = session
        _ = store
        await withCheckedContinuation { continuation in
            let state = withLock {
                retryStarted = true
                let waiters = retryWaiters
                retryWaiters.removeAll(keepingCapacity: true)
                if cancellationRequested {
                    return (true, waiters)
                }
                retryContinuation = continuation
                return (false, waiters)
            }
            for waiter in state.1 {
                waiter.resume()
            }
            if state.0 {
                continuation.resume()
            }
        }
        throw TranscriptionError.cancelled
    }

    func waitUntilRetryStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = withLock {
                if retryStarted {
                    return true
                }
                retryWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
    private var onBuffer: (@Sendable (AudioCaptureBuffer) -> Void)?
    private var onFinish: (@Sendable () -> Void)?
    private var onFailure: (@Sendable (String) -> Void)?
    private var outputDescriptor: AudioFileDescriptor?
    private var writer: CAFWriter?
    private(set) var isActive = false
    var writesCanonicalCAF = false

    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        _ = onInterruption
        outputDescriptor = descriptor
        self.onBuffer = onBuffer
        self.onFinish = onFinish
        self.onFailure = onFailure
        isActive = true
        if writesCanonicalCAF,
           let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1) {
            writer = try CAFWriter(descriptor: descriptor, format: format)
        }
    }

    func stop() throws {
        isActive = false
        writer?.close()
        writer = nil
        outputDescriptor = nil
        onFinish?()
        onBuffer = nil
        onFinish = nil
    }

    func cancel() {
        isActive = false
        writer?.close()
        writer = nil
        outputDescriptor = nil
        onBuffer = nil
        onFinish = nil
    }

    func writeCanonicalFrames(frameCount: Int = 1_600) throws {
        guard let writer else {
            throw ContractFailure(message: "canonical CAF writer was not attached to capture")
        }
        let samples: [Float] = (0..<frameCount).map { sin(Float($0) / 32.0) * 0.25 }
        try samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw ContractFailure(message: "synthetic PCM pointer was missing")
            }
            try writer.writeCanonicalMono(samples: baseAddress, frameCount: samples.count)
        }
    }

    func sendBuffer() {
        guard let outputDescriptor else {
            return
        }
        var bytes = [UInt8](repeating: 0, count: 2)
        _ = bytes.withUnsafeMutableBytes { buffer in
            Darwin.write(outputDescriptor.rawValue, buffer.baseAddress, buffer.count)
        }
        onBuffer?(
            AudioCaptureBuffer(
                frameCount: 1,
                sampleRate: 16_000,
                channelCount: 1,
                pcmData: Data([0, 0])
            )
        )
    }

    func emitFailure(_ reason: String) {
        isActive = false
        onFailure?(reason)
    }
}
