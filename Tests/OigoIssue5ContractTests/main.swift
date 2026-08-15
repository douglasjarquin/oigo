import Foundation
import OigoCore
import OigoTranscription

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
            ("failure and actionable errors", testFailureAndActionableErrors),
            ("saved-file retry", testSavedFileRetry)
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
              finalized.finalizedText == "hello world",
              finalized.volatileText.isEmpty,
              accumulated.finalizedText == "hello world again" else {
            throw ContractFailure(message: "volatile revisions were not replaced before final accumulation")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-live-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
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
    private static func testSavedFileRetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue5-retry-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let created = try store.createSession()
        let failed = try store.update(created, state: .failed, failureReason: "live analysis failed")
        try Data([0x43, 0x41, 0x46, 0x2D, 0x46, 0x49, 0x58, 0x54]).write(to: failed.audioURL, options: [.atomic])

        let retriedText = try SavedAudioRetry.retry(
            session: failed,
            liveFailure: TranscriptionError.analysisFailed("live fixture"),
            transcribe: { url in
                guard url == failed.audioURL else {
                    throw ContractFailure(message: "saved retry used a path other than audio.caf")
                }
                let persisted = try store.persistRawText("retried transcript", for: failed)
                _ = try store.update(
                    persisted,
                    state: .completed,
                    audioByteCount: Int64(try Data(contentsOf: url).count),
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

        try FileManager.default.removeItem(at: completed.audioURL)
        do {
            _ = try SavedAudioRetry.audioURL(
                for: completed,
                liveFailure: TranscriptionError.analysisFailed("malformed fixture")
            )
            throw ContractFailure(message: "missing saved audio unexpectedly passed retry validation")
        } catch let error as TranscriptionError {
            guard case .invalidSessionState = error else {
                throw ContractFailure(message: "retry state guard returned the wrong category: " + error.description)
            }
        }

        let interrupted = try store.update(completed, state: .interrupted, failureReason: "interrupted")
        do {
            _ = try SavedAudioRetry.audioURL(
                for: interrupted,
                liveFailure: TranscriptionError.analysisFailed("malformed fixture")
            )
            throw ContractFailure(message: "missing saved audio unexpectedly passed malformed-audio validation")
        } catch let error as TranscriptionError {
            guard case .malformedAudio = error else {
                throw ContractFailure(message: "missing saved audio returned the wrong category: " + error.description)
            }
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

    func cancel() async -> TranscriptionResult? {
        guard isRunning else {
            return nil
        }
        isRunning = false
        defer { clearResources() }
        return try? persist()
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
