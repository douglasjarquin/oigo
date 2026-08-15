import AVFAudio
import CoreMedia
import Foundation
import FoundationModels
import Speech

public enum NativePipelineError: Error, CustomStringConvertible {
    case microphonePermission(String)
    case analysisFailed(String)
    case missingApplicationBundle
    case notRestartable
    case alreadyRunning
    case notRunning

    public var description: String {
        switch self {
        case .microphonePermission(let permission):
            return "microphone permission is \(permission)"
        case .analysisFailed(let message):
            return "native dictation analysis failed: \(message)"
        case .missingApplicationBundle:
            return "native live capture requires an application bundle identifier"
        case .notRestartable:
            return "native dictation pipeline cannot be restarted after a start attempt"
        case .alreadyRunning:
            return "native dictation pipeline is already running"
        case .notRunning:
            return "native dictation pipeline is not running"
        }
    }
}

@available(macOS 26.0, *)
public final class NativeDictationPipeline: @unchecked Sendable {
    public let audioURL: URL
    public let transcriberChoice = "DictationTranscriber.progressiveLongDictation"

    private let engine = AVAudioEngine()
    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputStream: AsyncStream<AnalyzerInput>
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let transcriptStore = TranscriptStore()
    private let cleaner: FoundationModelsCleaner
    private let signposts: PipelineSignposts
    private let stateLock = NSLock()
    private var audioFile: AVAudioFile?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var running = false
    private var firstBufferSeen = false
    private var firstVolatileSeen = false
    private var failureDescription: String?
    private var lifecycleClosed = false
    private var snapshotHandler: (@Sendable (TranscriptSnapshot) -> Void)?
    private(set) public var lastError: String?

    public init(
        audioURL: URL,
        locale: Locale = Locale(identifier: "en-US"),
        signposts: PipelineSignposts = PipelineSignposts(),
        onSnapshot: (@Sendable (TranscriptSnapshot) -> Void)? = nil
    ) {
        self.audioURL = audioURL
        self.signposts = signposts
        self.cleaner = FoundationModelsCleaner(signposts: signposts)
        self.snapshotHandler = onSnapshot
        let transcriber = DictationTranscriber(
            locale: locale,
            preset: .progressiveLongDictation
        )
        self.transcriber = transcriber
        let streamPair = AsyncStream<AnalyzerInput>.makeStream()
        inputStream = streamPair.stream
        inputContinuation = streamPair.continuation
        let context = AnalysisContext()
        context.contextualStrings[.general] = [
            "Consigliere",
            "n8n",
            "Claude Code",
            "ChatGPT"
        ]
        analyzer = SpeechAnalyzer(
            inputSequence: streamPair.stream,
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .whileInUse
            ),
            analysisContext: context
        )
    }

    public var latestSnapshot: TranscriptSnapshot {
        transcriptStore.snapshot
    }

    public func start() async throws {
        try Self.requireApplicationBundle()
        try beginRun()
        do {
            let permission = AVAudioApplication.shared.recordPermission
            guard permission == .granted else {
                throw NativePipelineError.microphonePermission(String(describing: permission))
            }

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            try FileManager.default.createDirectory(
                at: audioURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let file = try AVAudioFile(
                forWriting: audioURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            audioFile = file

            try await analyzer.prepareToAnalyze(in: format)
            resultTask = Task { [weak self, transcriber] in
                do {
                    for try await result in transcriber.results {
                        self?.handle(result)
                    }
                } catch {
                    self?.record(error: error)
                }
            }
            analysisTask = Task { [weak self, analyzer, inputStream] in
                do {
                    try await analyzer.start(inputSequence: inputStream)
                } catch {
                    self?.record(error: error)
                }
            }

            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                guard let self else {
                    return
                }
                do {
                    try self.append(buffer)
                    self.inputContinuation.yield(AnalyzerInput(buffer: buffer))
                    self.markFirstBufferIfNeeded()
                } catch {
                    self.record(error: error)
                }
            }

            engine.prepare()
            try engine.start()
            signposts.mark(.recordingStart)
        } catch {
            await cleanupAfterStartFailure()
            throw error
        }
    }

    public func stop() async throws {
        try endRun()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation.finish()
        var finalizationError: Error?
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            record(error: error)
            finalizationError = error
        }
        _ = await analysisTask?.value
        _ = await resultTask?.value
        clearAudioFile()
        analysisTask = nil
        resultTask = nil
        signposts.mark(.resourceRelease)
        await SpeechModels.endRetention()
        if let finalizationError {
            throw finalizationError
        }
        if let failureDescription {
            throw NativePipelineError.analysisFailed(failureDescription)
        }
    }

    public func cleanFinalTranscript(
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> CleanupRecord {
        await cleaner.clean(
            rawText: latestSnapshot.finalizedText,
            timeoutNanoseconds: timeoutNanoseconds
        )
    }

    public func run(for seconds: TimeInterval) async throws {
        try await start()
        do {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        } catch {
            try? await stop()
            throw error
        }
        try await stop()
    }

    public func setSnapshotHandler(_ handler: (@Sendable (TranscriptSnapshot) -> Void)?) {
        stateLock.lock()
        snapshotHandler = handler
        stateLock.unlock()
    }

    public static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public static func capabilitySnapshot(
        locale: Locale = Locale(identifier: "en-US")
    ) async -> [String: String] {
        let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        let assetStatus = await AssetInventory.status(forModules: [module])
        let installedLocales = await DictationTranscriber.installedLocales
        let model = SystemLanguageModel.default
        return [
            "transcriber": "DictationTranscriber.progressiveLongDictation",
            "host_bundle_identifier": Bundle.main.bundleIdentifier ?? "none",
            "microphone_permission": microphonePermissionDescription(),
            "speech_assets": String(describing: assetStatus),
            "speech_installed_locales": installedLocales.map(\.identifier).joined(separator: ","),
            "foundation_models_availability": String(describing: model.availability),
            "foundation_models_available": String(model.isAvailable),
            "network_calls_in_oigo_path": "none"
        ]
    }

    public static func installSpeechAssets(
        locale: Locale = Locale(identifier: "en-US")
    ) async throws -> String {
        let module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            return String(describing: await AssetInventory.status(forModules: [module]))
        }
        try await request.downloadAndInstall()
        return String(describing: await AssetInventory.status(forModules: [module]))
    }

    public static func transcribeSavedAudio(
        at url: URL,
        locale: Locale = Locale(identifier: "en-US")
    ) async throws -> TranscriptSnapshot {
        try requireApplicationBundle()
        let transcriber = DictationTranscriber(
            locale: locale,
            preset: .progressiveLongDictation
        )
        let audioFile = try AVAudioFile(forReading: url)
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile,
            modules: [transcriber],
            options: SpeechAnalyzer.Options(
                priority: .userInitiated,
                modelRetention: .whileInUse
            ),
            finishAfterFile: true
        )
        let store = TranscriptStore()
        let resultTask = Task {
            for try await result in transcriber.results {
                let range = TranscriptRange(
                    startMilliseconds: Int64(result.range.start.seconds * 1_000),
                    endMilliseconds: Int64(result.range.end.seconds * 1_000)
                )
                _ = store.ingest(
                    range: range,
                    text: String(result.text.characters),
                    isFinal: result.isFinal
                )
            }
        }
        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await resultTask.value
        } catch {
            resultTask.cancel()
            _ = await resultTask.result
            await SpeechModels.endRetention()
            throw error
        }
        await SpeechModels.endRetention()
        return store.snapshot
    }

    private func append(_ buffer: AVAudioPCMBuffer) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        try audioFile?.write(from: buffer)
    }

    private func cleanupAfterStartFailure() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputContinuation.finish()
        analysisTask?.cancel()
        resultTask?.cancel()
        _ = await analysisTask?.value
        _ = await resultTask?.value
        analysisTask = nil
        resultTask = nil
        clearAudioFile()
        markStartFailureClosed()
        signposts.mark(.resourceRelease)
        await SpeechModels.endRetention()
    }

    private func clearAudioFile() {
        stateLock.lock()
        audioFile = nil
        stateLock.unlock()
    }

    private func markStartFailureClosed() {
        stateLock.lock()
        running = false
        lifecycleClosed = true
        stateLock.unlock()
    }

    private func markFirstBufferIfNeeded() {
        stateLock.lock()
        let shouldMark = !firstBufferSeen
        firstBufferSeen = true
        stateLock.unlock()
        if shouldMark {
            signposts.mark(.firstAudioBuffer)
        }
    }

    private func handle(_ result: DictationTranscriber.Result) {
        let range = TranscriptRange(
            startMilliseconds: Int64(result.range.start.seconds * 1_000),
            endMilliseconds: Int64(result.range.end.seconds * 1_000)
        )
        let snapshot = transcriptStore.ingest(
            range: range,
            text: String(result.text.characters),
            isFinal: result.isFinal
        )
        stateLock.lock()
        let handler = snapshotHandler
        let shouldMarkVolatile = !result.isFinal && !firstVolatileSeen
        if shouldMarkVolatile {
            firstVolatileSeen = true
        }
        stateLock.unlock()
        if shouldMarkVolatile {
            signposts.mark(.firstVolatileResult)
        }
        if result.isFinal {
            signposts.mark(.finalResult)
        }
        handler?(snapshot)
    }

    private func record(error: Error) {
        stateLock.lock()
        lastError = String(describing: error)
        if failureDescription == nil {
            failureDescription = lastError
        }
        stateLock.unlock()
    }

    private static func microphonePermissionDescription() -> String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .undetermined:
            return "undetermined"
        @unknown default:
            return "unknown"
        }
    }

    private static func requireApplicationBundle() throws {
        guard Bundle.main.bundleIdentifier != nil else {
            throw NativePipelineError.missingApplicationBundle
        }
    }

    private func beginRun() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !lifecycleClosed else {
            throw NativePipelineError.notRestartable
        }
        guard !running else {
            throw NativePipelineError.alreadyRunning
        }
        running = true
    }

    private func endRun() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running else {
            throw NativePipelineError.notRunning
        }
        running = false
        lifecycleClosed = true
    }
}
