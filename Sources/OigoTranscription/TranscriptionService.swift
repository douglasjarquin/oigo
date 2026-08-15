import AVFAudio
import CoreMedia
import Darwin
import Foundation
import OigoCore
import Speech

@available(macOS 26.0, *)
public final class TranscriptionService: TranscriptionController, @unchecked Sendable {
    private static let maxPreviewCharacters = 512

    private enum Lifecycle {
        case idle
        case starting
        case running
        case finishing
    }

    private struct Resources {
        let analyzer: SpeechAnalyzer
        let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
        let analysisTask: Task<Void, Never>
        let resultTask: Task<Void, Never>
    }

    private let lock = NSLock()
    private let configuredLocale: Locale
    private var lifecycle = Lifecycle.idle
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationRequested = false
    private var assetState: SpeechAssetState = .unavailable("speech assets have not been checked")
    private var resolvedLocaleIdentifier: String?
    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var pendingPreview: String?
    private var lastPreviewNanoseconds: UInt64 = 0
    private var transcriptStore = TranscriptStore()
    private var session: DictationSession?
    private var sessionStore: SessionStore?
    private var audioFormat: AVAudioFormat?
    private var updateHandler: (@Sendable (TranscriptionUpdate) -> Void)?
    private var analysisError: TranscriptionError?
    private var lastError: TranscriptionError?

    public init(locale: Locale = Locale(identifier: "en-US")) {
        configuredLocale = locale
    }

    public var configuredLocaleIdentifier: String {
        configuredLocale.identifier
    }

    public var currentAssetState: SpeechAssetState {
        lock.lock()
        defer { lock.unlock() }
        return assetState
    }

    public var currentResolvedLocaleIdentifier: String? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedLocaleIdentifier
    }

    public var latestSnapshot: TranscriptionSnapshot {
        transcriptStore.snapshot
    }

    public var lastTranscriptionError: TranscriptionError? {
        lock.lock()
        defer { lock.unlock() }
        return lastError
    }

    public func checkSpeechAssets() async throws -> SpeechAssetState {
        let inspection = try await inspectAssets()
        return try applyAssetStatus(inspection.status, localeIdentifier: inspection.locale.identifier)
    }

    @discardableResult
    public func installSpeechAssets() async throws -> SpeechAssetState {
        let inspection = try await inspectAssets()
        switch inspection.status {
        case .installed:
            return try applyAssetStatus(.installed, localeIdentifier: inspection.locale.identifier)
        case .unsupported:
            return try applyAssetStatus(.unsupported, localeIdentifier: inspection.locale.identifier)
        case .downloading:
            setAssetState(.installing(inspection.locale.identifier))
            throw remember(.speechAssetsInstalling(inspection.locale.identifier))
        case .supported:
            setAssetState(.installing(inspection.locale.identifier))
            do {
                guard let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [inspection.module]
                ) else {
                    return try applyAssetStatus(
                        await AssetInventory.status(forModules: [inspection.module]),
                        localeIdentifier: inspection.locale.identifier
                    )
                }
                try await request.downloadAndInstall()
            } catch let error as TranscriptionError {
                throw error
            } catch {
                throw remember(.speechAssetsUnavailable(String(describing: error)))
            }
            let status = await AssetInventory.status(forModules: [inspection.module])
            return try applyAssetStatus(status, localeIdentifier: inspection.locale.identifier)
        @unknown default:
            throw remember(.speechAssetsUnavailable("the speech asset inventory returned an unknown status"))
        }
    }

    public func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        guard format.isValid, format.channelCount == 1 else {
            throw remember(.invalidCaptureFormat)
        }

        guard beginStarting() else {
            throw remember(.alreadyRunning)
        }

        var preparedAnalyzer: SpeechAnalyzer?
        var preparedInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        var startupGate: TranscriptionStartupGate?
        var startupResultTask: Task<Void, Never>?
        var startupAnalysisTask: Task<Void, Never>?
        do {
            let module = try await installedTranscriber()
            try checkCancellationRequested()
            guard let audioFormat = AVAudioFormat(
                standardFormatWithSampleRate: format.sampleRate,
                channels: AVAudioChannelCount(format.channelCount)
            ) else {
                throw TranscriptionError.invalidCaptureFormat
            }

            let streamPair = AsyncStream<AnalyzerInput>.makeStream()
            preparedInputContinuation = streamPair.continuation
            let analyzer = SpeechAnalyzer(
                inputSequence: streamPair.stream,
                modules: [module],
                options: SpeechAnalyzer.Options(
                    priority: .userInitiated,
                    modelRetention: .whileInUse
                )
            )
            preparedAnalyzer = analyzer

            try await analyzer.prepareToAnalyze(in: audioFormat)
            try checkCancellationRequested()
            do {
                _ = try store.persistRawText("", for: session)
            } catch {
                throw TranscriptionError.persistenceFailed(String(describing: error))
            }
            let gate = TranscriptionStartupGate()
            startupGate = gate
            let resultTask = Task { [weak self, module, startupStream = gate.resultStream] in
                for await _ in startupStream {
                    break
                }
                do {
                    for try await result in module.results {
                        try Task.checkCancellation()
                        self?.consume(result)
                    }
                } catch is CancellationError {
                } catch {
                    self?.record(error: Self.map(error))
                }
            }
            let analysisTask = Task { [weak self, analyzer, stream = streamPair.stream, startupStream = gate.analysisStream] in
                for await _ in startupStream {
                    break
                }
                do {
                    try await analyzer.start(inputSequence: stream)
                } catch is CancellationError {
                } catch {
                    self?.record(error: Self.map(error))
                }
            }
            startupResultTask = resultTask
            startupAnalysisTask = analysisTask

            let published = withLock {
                guard lifecycle == .starting, !cancellationRequested else {
                    return false
                }
                lifecycle = .running
                transcriber = module
                self.analyzer = analyzer
                inputContinuation = streamPair.continuation
                self.audioFormat = audioFormat
                self.session = session
                sessionStore = store
                updateHandler = onUpdate
                transcriptStore = TranscriptStore()
                analysisError = nil
                lastError = nil
                self.resultTask = resultTask
                self.analysisTask = analysisTask
                return true
            }
            guard published else {
                gate.finish()
                throw TranscriptionError.cancelled
            }
            gate.release()
            startupGate = nil
            resumeStartWaiters()
        } catch {
            startupGate?.finish()
            startupResultTask?.cancel()
            startupAnalysisTask?.cancel()
            if let startupResultTask {
                _ = await startupResultTask.value
            }
            if let startupAnalysisTask {
                _ = await startupAnalysisTask.value
            }
            preparedInputContinuation?.finish()
            if let preparedAnalyzer {
                await preparedAnalyzer.cancelAndFinishNow()
            }
            finishStarting()
            await SpeechModels.endRetention()
            throw remember(Self.map(error))
        }
    }

    public func append(_ buffer: AudioCaptureBuffer) {
        lock.lock()
        guard lifecycle == .running,
              let audioFormat,
              let inputContinuation else {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            let pcmBuffer = try makePCMBuffer(buffer, format: audioFormat)
            inputContinuation.yield(AnalyzerInput(buffer: pcmBuffer))
        } catch {
            record(error: Self.map(error))
            inputContinuation.finish()
        }
    }

    public func finish() async throws -> TranscriptionResult {
        guard let resources = takeResources() else {
            throw remember(.notRunning)
        }

        resources.inputContinuation.finish()
        var finalError: TranscriptionError?
        do {
            try await resources.analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            finalError = Self.map(error)
            record(error: finalError ?? .analysisFailed(String(describing: error)))
        }
        _ = await resources.analysisTask.value
        _ = await resources.resultTask.value
        await finishPreviewTask()

        if finalError == nil {
            finalError = currentAnalysisError()
        }

        let snapshot = transcriptStore.snapshot
        var finalizedText = snapshot.finalizedText
        var rawTextByteCount = Int64(Data(snapshot.finalizedText.utf8).count)
        do {
            let persisted = try persistCanonicalRawText()
            finalizedText = persisted.text
            rawTextByteCount = persisted.rawTextByteCount
        } catch {
            finalError = Self.map(error)
            record(error: finalError ?? .persistenceFailed(String(describing: error)))
        }
        let result = TranscriptionResult(
            finalizedText: finalizedText,
            rawTextByteCount: rawTextByteCount
        )
        await releaseResources()
        if let finalError {
            throw finalError
        }
        return result
    }

    public func cancel() async throws -> TranscriptionResult? {
        if withLock({
            if lifecycle == .starting {
                cancellationRequested = true
                return true
            }
            return false
        }) {
            await waitForStartToFinish()
        }
        guard let resources = takeResources() else {
            return nil
        }

        resources.inputContinuation.finish()
        resources.analysisTask.cancel()
        resources.resultTask.cancel()
        await resources.analyzer.cancelAndFinishNow()
        _ = await resources.analysisTask.value
        _ = await resources.resultTask.value
        await finishPreviewTask()

        let persisted: (text: String, rawTextByteCount: Int64)
        do {
            persisted = try persistCanonicalRawText()
        } catch {
            await releaseResources()
            throw Self.map(error)
        }
        let result = TranscriptionResult(
            finalizedText: persisted.text,
            rawTextByteCount: persisted.rawTextByteCount
        )
        await releaseResources()
        return result
    }

    public func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        try await retrySavedAudio(
            for: session,
            store: store,
            liveFailure: TranscriptionError.analysisFailed("live recognition failed")
        )
    }

    public func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore,
        liveFailure: Error = TranscriptionError.analysisFailed("live recognition failed")
    ) async throws -> TranscriptionResult {
        guard beginStarting() else {
            throw remember(.alreadyRunning)
        }
        defer { finishStarting() }

        let url = try SavedAudioRetry.audioURL(for: session, liveFailure: liveFailure)
        let module = try await installedTranscriber()
        try checkCancellationRequested()
        let securedAudioFile: SecuredAudioFile
        do {
            securedAudioFile = try SavedAudioRetry.openAudioFile(
                for: session,
                store: store,
                liveFailure: liveFailure
            )
        } catch let error as TranscriptionError {
            throw remember(error)
        } catch {
            throw remember(.malformedAudio(url, String(describing: error)))
        }
        let audioFile = securedAudioFile.file
        do {
            _ = try store.persistRawText("", for: session)
        } catch {
            await SpeechModels.endRetention()
            throw remember(.persistenceFailed(String(describing: error)))
        }

        var createdAnalyzer: SpeechAnalyzer?
        do {
            createdAnalyzer = try await SpeechAnalyzer(
                inputAudioFile: audioFile,
                modules: [module],
                options: SpeechAnalyzer.Options(
                    priority: .userInitiated,
                    modelRetention: .whileInUse
                ),
                finishAfterFile: true
            )
            try checkCancellationRequested()
        } catch {
            if let createdAnalyzer {
                await createdAnalyzer.cancelAndFinishNow()
            }
            await SpeechModels.endRetention()
            throw remember(Self.map(error))
        }
        guard let analyzer = createdAnalyzer else {
            throw remember(.recognitionUnavailable("speech analyzer could not be created"))
        }

        let transcriptStore = TranscriptStore()
        let resultTask = Task {
            do {
                for try await result in module.results {
                    try Task.checkCancellation()
                    let ingested = transcriptStore.ingestAndReport(result)
                    if let finalText = ingested.acceptedFinalText {
                        try appendCanonicalFinal(
                            finalText,
                            for: session,
                            store: store
                        )
                    }
                }
            } catch is CancellationError {
            } catch {
                throw Self.map(error)
            }
        }

        do {
            try Task.checkCancellation()
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            try checkCancellationRequested()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try checkCancellationRequested()
            _ = try await resultTask.value
            try checkCancellationRequested()
        } catch is CancellationError {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            _ = try? await resultTask.value
            await SpeechModels.endRetention()
            throw remember(.cancelled)
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            _ = try? await resultTask.value
            await SpeechModels.endRetention()
            throw remember(Self.map(error))
        }

        do {
            let persisted = try persistCanonicalRawText(for: session, store: store)
            _ = try store.update(
                session,
                state: .completed,
                audioByteCount: securedAudioFile.byteCount,
                rawTextByteCount: persisted.rawTextByteCount
            )
            await SpeechModels.endRetention()
            return TranscriptionResult(
                finalizedText: persisted.text,
                rawTextByteCount: persisted.rawTextByteCount
            )
        } catch {
            await SpeechModels.endRetention()
            throw remember(.persistenceFailed(String(describing: error)))
        }
    }

    private func inspectAssets() async throws -> (module: DictationTranscriber, locale: Locale, status: AssetInventory.Status) {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: configuredLocale) else {
            setAssetState(.unavailable("the selected locale has no compatible on-device model"))
            throw remember(.unsupportedLocale(configuredLocale.identifier))
        }
        let module = DictationTranscriber(
            locale: locale,
            preset: .progressiveLongDictation
        )
        let status = await AssetInventory.status(forModules: [module])
        return (module, locale, status)
    }

    private func installedTranscriber() async throws -> DictationTranscriber {
        let inspection = try await inspectAssets()
        _ = try applyAssetStatus(inspection.status, localeIdentifier: inspection.locale.identifier)
        return inspection.module
    }

    private func applyAssetStatus(
        _ status: AssetInventory.Status,
        localeIdentifier: String
    ) throws -> SpeechAssetState {
        switch status {
        case .installed:
            let state = SpeechAssetState.ready(localeIdentifier)
            setAssetState(state, localeIdentifier: localeIdentifier)
            return state
        case .downloading:
            setAssetState(.installing(localeIdentifier), localeIdentifier: localeIdentifier)
            throw remember(.speechAssetsInstalling(localeIdentifier))
        case .supported:
            let reason = "install the Apple-managed speech assets before recording"
            setAssetState(.unavailable(reason), localeIdentifier: localeIdentifier)
            throw remember(.speechAssetsUnavailable(reason))
        case .unsupported:
            let reason = "the selected locale has no compatible on-device model"
            setAssetState(.unavailable(reason), localeIdentifier: localeIdentifier)
            throw remember(.recognitionUnavailable(reason))
        @unknown default:
            let reason = "the speech asset inventory returned an unknown status"
            setAssetState(.unavailable(reason), localeIdentifier: localeIdentifier)
            throw remember(.speechAssetsUnavailable(reason))
        }
    }

    private func setAssetState(
        _ state: SpeechAssetState,
        localeIdentifier: String? = nil
    ) {
        lock.lock()
        assetState = state
        if let localeIdentifier {
            resolvedLocaleIdentifier = localeIdentifier
        }
        lock.unlock()
    }

    private func beginStarting() -> Bool {
        withLock {
            guard lifecycle == .idle else {
                return false
            }
            lifecycle = .starting
            cancellationRequested = false
            return true
        }
    }

    private func finishStarting() {
        withLock {
            if lifecycle == .starting {
                lifecycle = .idle
            }
            cancellationRequested = false
        }
        resumeStartWaiters()
    }

    private func waitForStartToFinish() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = withLock {
                guard lifecycle == .starting else {
                    return true
                }
                startWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func resumeStartWaiters() {
        let waiters = withLock {
            let waiters = startWaiters
            startWaiters.removeAll(keepingCapacity: true)
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func checkCancellationRequested() throws {
        if withLock({ cancellationRequested }) || Task.isCancelled {
            throw TranscriptionError.cancelled
        }
    }

    private func takeResources() -> Resources? {
        lock.lock()
        defer { lock.unlock() }
        guard lifecycle == .running,
              let analyzer,
              let inputContinuation,
              let analysisTask,
              let resultTask else {
            return nil
        }
        lifecycle = .finishing
        self.analyzer = nil
        self.inputContinuation = nil
        self.analysisTask = nil
        self.resultTask = nil
        return Resources(
            analyzer: analyzer,
            inputContinuation: inputContinuation,
            analysisTask: analysisTask,
            resultTask: resultTask
        )
    }

    private func releaseResources() async {
        withLock {
            transcriber = nil
            analyzer = nil
            inputContinuation = nil
            analysisTask = nil
            resultTask = nil
            previewTask = nil
            pendingPreview = nil
            session = nil
            sessionStore = nil
            audioFormat = nil
            updateHandler = nil
            analysisError = nil
            cancellationRequested = false
            lifecycle = .idle
        }
        await SpeechModels.endRetention()
    }

    private func finishPreviewTask() async {
        let previewTask = withLock {
            let task = self.previewTask
            self.previewTask = nil
            pendingPreview = nil
            return task
        }
        previewTask?.cancel()
        _ = await previewTask?.value
    }

    private func consume(_ result: DictationTranscriber.Result) {
        let start = max(0, result.range.start.seconds)
        let end = max(start, result.range.end.seconds)
        let range = TranscriptionRange(
            startMilliseconds: Int64(start * 1_000),
            endMilliseconds: Int64(end * 1_000)
        )
        let text = String(result.text.characters)
        let ingested = transcriptStore.ingestAndReport(
            range: range,
            text: text,
            isFinal: result.isFinal
        )
        if result.isFinal {
            guard let finalText = ingested.acceptedFinalText else {
                return
            }
            do {
                try appendCanonicalFinal(finalText)
            } catch {
                record(error: Self.map(error))
            }
            let handler = currentUpdateHandler()
            handler?(TranscriptionUpdate(
                finalizedSegment: finalText,
                volatilePreview: "",
                isFinal: true
            ))
        } else {
            schedulePreview(text)
        }
    }

    private func schedulePreview(_ text: String) {
        let preview = String(text.prefix(Self.maxPreviewCharacters))
        lock.lock()
        pendingPreview = preview
        guard previewTask == nil else {
            lock.unlock()
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let interval: UInt64 = 200_000_000
        let elapsed = now >= lastPreviewNanoseconds ? now - lastPreviewNanoseconds : interval
        let delay = elapsed >= interval ? 0 : interval - elapsed
        previewTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            self?.flushPreview()
        }
        lock.unlock()
    }

    private func flushPreview() {
        let payload: (String, (@Sendable (TranscriptionUpdate) -> Void)?)? = withLock {
            guard lifecycle == .running, let text = pendingPreview else {
                pendingPreview = nil
                previewTask = nil
                return nil
            }
            pendingPreview = nil
            previewTask = nil
            lastPreviewNanoseconds = DispatchTime.now().uptimeNanoseconds
            return (text, updateHandler)
        }
        guard let (text, handler) = payload, let handler else {
            return
        }
        handler(TranscriptionUpdate(
            finalizedSegment: nil,
            volatilePreview: text,
            isFinal: false
        ))
    }

    private func currentUpdateHandler() -> (@Sendable (TranscriptionUpdate) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return updateHandler
    }

    private func currentAnalysisError() -> TranscriptionError? {
        withLock { analysisError }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func appendCanonicalFinal(_ text: String) throws {
        lock.lock()
        let session = self.session
        let store = sessionStore
        lock.unlock()
        guard let session, let store else {
            throw TranscriptionError.persistenceFailed("transcription session is no longer available")
        }
        try appendCanonicalFinal(text, for: session, store: store)
    }

    private func appendCanonicalFinal(
        _ text: String,
        for session: DictationSession,
        store: SessionStore
    ) throws {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return
        }
        do {
            _ = try store.appendRawText(normalizedText, for: session)
        } catch {
            throw TranscriptionError.persistenceFailed(String(describing: error))
        }
    }

    private func persistCanonicalRawText() throws -> (text: String, rawTextByteCount: Int64) {
        lock.lock()
        let session = self.session
        let store = sessionStore
        lock.unlock()
        guard let session, let store else {
            throw TranscriptionError.persistenceFailed("transcription session is no longer available")
        }
        return try persistCanonicalRawText(for: session, store: store)
    }

    private func persistCanonicalRawText(
        for session: DictationSession,
        store: SessionStore
    ) throws -> (text: String, rawTextByteCount: Int64) {
        do {
            let rawText = try store.readRawText(for: session)
            _ = try store.persistRawText(rawText, for: session)
            return (rawText, Int64(Data(rawText.utf8).count))
        } catch {
            throw TranscriptionError.persistenceFailed(String(describing: error))
        }
    }

    private func record(error: TranscriptionError) {
        lock.lock()
        if analysisError == nil {
            analysisError = error
        }
        lastError = error
        lock.unlock()
    }

    private func remember(_ error: TranscriptionError) -> TranscriptionError {
        lock.lock()
        lastError = error
        lock.unlock()
        return error
    }

    private static func map(_ error: Error) -> TranscriptionError {
        if let error = error as? TranscriptionError {
            return error
        }
        if error is CancellationError || Task.isCancelled {
            return .cancelled
        }
        return .analysisFailed(String(describing: error))
    }

    private func makePCMBuffer(
        _ captureBuffer: AudioCaptureBuffer,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard captureBuffer.frameCount > 0,
              captureBuffer.sampleRate == format.sampleRate,
              captureBuffer.channelCount == Int(format.channelCount),
              let pcmBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(captureBuffer.frameCount)
              ),
              let destination = pcmBuffer.floatChannelData?.pointee else {
            throw TranscriptionError.malformedAudio(
                URL(fileURLWithPath: "<live-buffer>"),
                "capture buffer does not match the prepared mono PCM format"
            )
        }
        pcmBuffer.frameLength = AVAudioFrameCount(captureBuffer.frameCount)
        let destinationByteCount = captureBuffer.frameCount * MemoryLayout<Float>.size
        memset(destination, 0, destinationByteCount)
        captureBuffer.pcmData.withUnsafeBytes { source in
            guard let baseAddress = source.baseAddress else {
                return
            }
            memcpy(
                destination,
                baseAddress,
                min(destinationByteCount, captureBuffer.pcmData.count)
            )
        }
        return pcmBuffer
    }

}
