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
            ("canonical final replacement", testCanonicalFinalReplacement)
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
        let immediateResult = Task {
            var accumulator = TranscriptionAccumulator()
            return accumulator.ingest(
                range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 100),
                text: "published before analysis work",
                isFinal: true
            )
        }
        let snapshot = await immediateResult.value
        guard snapshot.finalizedText == "published before analysis work",
              snapshot.volatileText.isEmpty,
              snapshot.displayedText == snapshot.finalizedText else {
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
        let broadCorrection = (0..<12)
            .map { "segment-" + String($0) }
            .joined(separator: " ")
        try persist(
            compactedAccumulator.ingestAndReport(
                range: TranscriptionRange(startMilliseconds: 0, endMilliseconds: 1_200),
                text: broadCorrection,
                isFinal: true
            ).finalization,
            for: &compactedSession
        )
        guard try store.readRawText(for: compactedSession) == canonicalBeforeBroadCorrection else {
            throw ContractFailure(message: "compacted-history correction duplicated the durable canonical prefix")
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
    private var outputURL: URL?
    private(set) var isActive = false

    func start(
        to url: URL,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        _ = onInterruption
        _ = onFailure
        outputURL = url
        try Data().write(to: url, options: [.atomic])
        self.onBuffer = onBuffer
        self.onFinish = onFinish
        isActive = true
    }

    func stop() throws {
        isActive = false
        outputURL = nil
        onFinish?()
        onBuffer = nil
        onFinish = nil
    }

    func cancel() {
        isActive = false
        outputURL = nil
        onBuffer = nil
        onFinish = nil
    }

    func sendBuffer() {
        try? Data([0, 0]).write(to: outputURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("unused"), options: [.atomic])
        onBuffer?(
            AudioCaptureBuffer(
                frameCount: 1,
                sampleRate: 16_000,
                channelCount: 1,
                pcmData: Data([0, 0])
            )
        )
    }
}
