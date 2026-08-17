import AVFAudio
import CoreMedia
import Darwin
import Foundation
@_spi(Testing) import OigoCore
import Speech

private final class AudioPCMBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

private final class AudioConverterInputState: @unchecked Sendable {
    var supplied = false
}

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
    private let faultInjector: DictationFaultInjector?
    private let instrumentation: PerformanceInstrumentation
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
    private var firstVolatileResultReported = false
    private var transcriptStore = TranscriptStore()
    private var session: DictationSession?
    private var sessionStore: SessionStore?
    private var audioFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?
    private var updateHandler: (@Sendable (TranscriptionUpdate) -> Void)?
    private var analysisError: TranscriptionError?
    private var lastError: TranscriptionError?

    public init(
        locale: Locale = Locale(identifier: "en-US"),
        instrumentation: PerformanceInstrumentation = OSLogPerformanceInstrumentation()
    ) {
        configuredLocale = locale
        faultInjector = nil
        self.instrumentation = instrumentation
    }

    @_spi(Testing)
    public init(
        locale: Locale = Locale(identifier: "en-US"),
        faultInjector: DictationFaultInjector?,
        instrumentation: PerformanceInstrumentation = OSLogPerformanceInstrumentation()
    ) {
        configuredLocale = locale
        self.faultInjector = faultInjector
        self.instrumentation = instrumentation
    }

    @_spi(Testing)
    public static func analyzerAudioFormat(
        for captureFormat: AudioCaptureFormat,
        compatibleWith module: DictationTranscriber
    ) async -> AVAudioFormat? {
        guard captureFormat.isValid,
              let naturalFormat = AVAudioFormat(
                  standardFormatWithSampleRate: captureFormat.sampleRate,
                  channels: AVAudioChannelCount(captureFormat.channelCount)
              ) else {
            return nil
        }
        return await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module],
            considering: naturalFormat
        )
    }

    @_spi(Testing)
    public static func convertCaptureBufferForTesting(
        _ captureBuffer: AudioCaptureBuffer,
        to analyzerFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let captureFormat = AVAudioFormat(
            standardFormatWithSampleRate: captureBuffer.sampleRate,
            channels: AVAudioChannelCount(captureBuffer.channelCount)
        ), let converter = AVAudioConverter(
            from: captureFormat,
            to: analyzerFormat
        ) else {
            throw TranscriptionError.invalidCaptureFormat
        }
        converter.primeMethod = .none
        return try TranscriptionService().makePCMBuffer(
            captureBuffer,
            format: analyzerFormat,
            converter: converter
        )
    }

    @_spi(Testing)
    public func deliverFinalAtStartupBoundaryForTesting(
        range: TranscriptionRange,
        text: String
    ) async throws -> TranscriptionSnapshot {
        guard beginStarting() else {
            throw remember(.alreadyRunning)
        }

        if faultInjector?.consume(.speechFailure) == true {
            finishStarting()
            await releaseResources()
            throw remember(.analysisFailed("fault injection: speech failure"))
        }

        let gate = TranscriptionStartupGate()
        let resultTask = Task { [weak self, startupStream = gate.resultStream] in
            for await _ in startupStream {
                break
            }
            self?.consume(
                range: range,
                text: text,
                isFinal: true,
                persistCanonical: false
            )
        }
        let published = publishStartingState(
            module: nil,
            analyzer: nil,
            inputContinuation: nil,
            audioFormat: nil,
            session: nil,
            store: nil,
            updateHandler: nil,
            resultTask: resultTask,
            analysisTask: nil,
            transcriptStore: TranscriptStore(),
            audioConverter: nil
        )
        guard published else {
            gate.finish()
            resultTask.cancel()
            _ = await resultTask.value
            await releaseResources()
            throw remember(.cancelled)
        }

        gate.release()
        _ = await resultTask.value
        let snapshot = latestSnapshot
        instrumentation.mark(.transcriptionFinalized)
        await releaseResources()
        return snapshot
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

    public func supportedLocaleIdentifiers() async -> [String] {
        await DictationTranscriber.supportedLocales
            .map(\.identifier)
            .sorted()
    }

    public func closestSupportedLocaleIdentifier() async -> String? {
        let identifiers = await supportedLocaleIdentifiers()
        return OigoSupportedLocaleResolver.closest(
            to: configuredLocale.identifier,
            among: identifiers
        )
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
                setAssetState(.failed(error.description))
                throw error
            } catch {
                let reason = String(describing: error)
                setAssetState(.failed(reason))
                throw remember(.speechAssetsFailed(reason))
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
            guard let captureAudioFormat = AVAudioFormat(
                standardFormatWithSampleRate: format.sampleRate,
                channels: AVAudioChannelCount(format.channelCount)
            ), let audioFormat = await Self.analyzerAudioFormat(
                for: format,
                compatibleWith: module
            ), let audioConverter = AVAudioConverter(
                from: captureAudioFormat,
                to: audioFormat
            ) else {
                throw TranscriptionError.invalidCaptureFormat
            }
            audioConverter.primeMethod = .none

            let streamPair = AsyncStream<AnalyzerInput>.makeStream()
            preparedInputContinuation = streamPair.continuation
            let analyzer = SpeechAnalyzer(
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

            let published = publishStartingState(
                module: module,
                analyzer: analyzer,
                inputContinuation: streamPair.continuation,
                audioFormat: audioFormat,
                session: session,
                store: store,
                updateHandler: onUpdate,
                resultTask: resultTask,
                analysisTask: analysisTask,
                transcriptStore: TranscriptStore(),
                audioConverter: audioConverter
            )
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
            await releaseResources()
            throw remember(Self.map(error))
        }
    }

    public func append(_ buffer: AudioCaptureBuffer) {
        lock.lock()
        guard lifecycle == .running,
              let audioFormat,
              let audioConverter,
              let inputContinuation else {
            lock.unlock()
            return
        }
        lock.unlock()

        do {
            let pcmBuffer = try makePCMBuffer(
                buffer,
                format: audioFormat,
                converter: audioConverter
            )
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
        instrumentation.mark(.transcriptionFinalized)
        await releaseResources()
        if let finalError {
            throw finalError
        }
        return result
    }

    public func cancel() async throws -> TranscriptionResult? {
        let startingResources: (SpeechAnalyzer?, Task<Void, Never>?)? = withLock {
            guard lifecycle == .starting else {
                return nil
            }
            cancellationRequested = true
            return (analyzer, resultTask)
        }
        if let startingResources {
            startingResources.1?.cancel()
            if let analyzer = startingResources.0 {
                await analyzer.cancelAndFinishNow()
            }
            await waitForStartToFinish()
            return nil
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
        defer {
            finishStarting()
            instrumentation.mark(.resourcesReleased)
        }

        if faultInjector?.consume(.speechFailure) == true {
            throw remember(.analysisFailed("fault injection: speech failure"))
        }

        let url = session.audioURL
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
        let staging: RawTextStaging
        do {
            staging = try store.beginRawTextStaging(for: session)
        } catch {
            await SpeechModels.endRetention()
            throw remember(.persistenceFailed(String(describing: error)))
        }
        var stagingCommitted = false
        defer {
            if !stagingCommitted {
                try? store.discardRawTextStaging(staging, for: session)
            }
        }
        defer { clearRetryResources() }

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
            await SpeechModels.endRetention()
            throw remember(.recognitionUnavailable("speech analyzer could not be created"))
        }

        let transcriptStore = TranscriptStore()
        let resultTask = Task { [weak self, module, transcriptStore] in
            do {
                for try await result in module.results {
                    try Task.checkCancellation()
                    let ingested = transcriptStore.ingestAndReport(result)
                    if let finalization = ingested.finalization {
                        try Self.applyStagedFinalization(finalization, staging: staging, for: session, store: store)
                    }
                }
            } catch is CancellationError {
            } catch {
                self?.record(error: Self.map(error))
            }
        }

        let published = withLock {
            guard lifecycle == .starting else {
                return false
            }
            transcriber = module
            self.analyzer = analyzer
            self.resultTask = resultTask
            self.session = session
            sessionStore = store
            self.transcriptStore = transcriptStore
            analysisError = nil
            return !cancellationRequested
        }
        guard published else {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            _ = await resultTask.value
            await SpeechModels.endRetention()
            throw remember(.cancelled)
        }

        do {
            try Task.checkCancellation()
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            try checkCancellationRequested()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try checkCancellationRequested()
            _ = await resultTask.value
            if let analysisError = currentAnalysisError() {
                throw analysisError
            }
            try checkCancellationRequested()
        } catch is CancellationError {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            _ = await resultTask.value
            await SpeechModels.endRetention()
            throw remember(.cancelled)
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            _ = await resultTask.value
            await SpeechModels.endRetention()
            throw remember(Self.map(error))
        }

        do {
            let persistedSession = try store.commitRawTextStaging(staging, for: session)
            stagingCommitted = true
            let rawText = try store.readRawText(for: persistedSession)
            let rawTextByteCount = Int64(Data(rawText.utf8).count)
            _ = try store.update(
                persistedSession,
                state: .completed,
                audioByteCount: securedAudioFile.byteCount,
                rawTextByteCount: rawTextByteCount
            )
            await SpeechModels.endRetention()
            instrumentation.mark(.transcriptionFinalized)
            return TranscriptionResult(
                finalizedText: rawText,
                rawTextByteCount: rawTextByteCount
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
            firstVolatileResultReported = false
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
            audioConverter = nil
            updateHandler = nil
            analysisError = nil
            cancellationRequested = false
            lifecycle = .idle
        }
        await SpeechModels.endRetention()
        instrumentation.mark(.resourcesReleased)
    }

    private func clearRetryResources() {
        withLock {
            transcriber = nil
            analyzer = nil
            resultTask = nil
            session = nil
            sessionStore = nil
            analysisError = nil
        }
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
        consume(
            range: TranscriptionRange(
                startMilliseconds: Int64(start * 1_000),
                endMilliseconds: Int64(end * 1_000)
            ),
            text: String(result.text.characters),
            isFinal: result.isFinal,
            persistCanonical: true
        )
    }

    private func consume(
        range: TranscriptionRange,
        text: String,
        isFinal: Bool,
        persistCanonical: Bool
    ) {
        let ingested = transcriptStore.ingestAndReport(
            range: range,
            text: text,
            isFinal: isFinal
        )
        if isFinal {
            guard let finalization = ingested.finalization else {
                return
            }
            if persistCanonical {
                do {
                    try applyCanonicalFinalization(finalization)
                } catch {
                    record(error: Self.map(error))
                }
            }
            let handler = currentUpdateHandler()
            handler?(TranscriptionUpdate(
                finalizedSegment: finalization.emittedText,
                volatilePreview: "",
                isFinal: true
            ))
        } else {
            let shouldMark = withLock {
                guard !firstVolatileResultReported else {
                    return false
                }
                firstVolatileResultReported = true
                return true
            }
            if shouldMark {
                instrumentation.mark(.firstVolatileResult)
            }
            schedulePreview(text)
        }
    }

    private func publishStartingState(
        module: DictationTranscriber?,
        analyzer: SpeechAnalyzer?,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation?,
        audioFormat: AVAudioFormat?,
        session: DictationSession?,
        store: SessionStore?,
        updateHandler: (@Sendable (TranscriptionUpdate) -> Void)?,
        resultTask: Task<Void, Never>?,
        analysisTask: Task<Void, Never>?,
        transcriptStore: TranscriptStore,
        audioConverter: AVAudioConverter?
    ) -> Bool {
        withLock {
            guard lifecycle == .starting, !cancellationRequested else {
                return false
            }
            lifecycle = .running
            transcriber = module
            self.analyzer = analyzer
            self.inputContinuation = inputContinuation
            self.audioFormat = audioFormat
            self.audioConverter = audioConverter
            self.session = session
            sessionStore = store
            self.updateHandler = updateHandler
            self.transcriptStore = transcriptStore
            analysisError = nil
            lastError = nil
            self.resultTask = resultTask
            self.analysisTask = analysisTask
            return true
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

    private func applyCanonicalFinalization(_ finalization: TranscriptFinalization) throws {
        lock.lock()
        let session = self.session
        let store = sessionStore
        lock.unlock()
        guard let session, let store else {
            throw TranscriptionError.persistenceFailed("transcription session is no longer available")
        }
        try applyCanonicalFinalization(finalization, for: session, store: store)
    }

    private func applyCanonicalFinalization(
        _ finalization: TranscriptFinalization,
        for session: DictationSession,
        store: SessionStore
    ) throws {
        do {
            switch finalization {
            case .append(let text):
                _ = try store.appendRawText(text, for: session)
            case .replace(let existing, let replacement):
                _ = try store.replaceRawTextTail(existing, with: replacement, for: session)
            }
        } catch {
            throw TranscriptionError.persistenceFailed(String(describing: error))
        }
    }

    private static func applyStagedFinalization(
        _ finalization: TranscriptFinalization,
        staging: RawTextStaging,
        for session: DictationSession,
        store: SessionStore
    ) throws {
        do {
            switch finalization {
            case .append(let text):
                try store.appendRawText(text, to: staging, for: session)
            case .replace(let existing, let replacement):
                try store.replaceRawTextStagingTail(
                    existing,
                    with: replacement,
                    to: staging,
                    for: session
                )
            }
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
        format: AVAudioFormat,
        converter: AVAudioConverter
    ) throws -> AVAudioPCMBuffer {
        guard captureBuffer.frameCount > 0,
              captureBuffer.sampleRate.isFinite,
              captureBuffer.sampleRate > 0,
              captureBuffer.channelCount == 1,
              format.commonFormat == .pcmFormatInt16,
              format.isInterleaved,
              let captureFormat = AVAudioFormat(
                  standardFormatWithSampleRate: captureBuffer.sampleRate,
                  channels: AVAudioChannelCount(captureBuffer.channelCount)
              ),
              let capturePCMBuffer = AVAudioPCMBuffer(
                pcmFormat: captureFormat,
                frameCapacity: AVAudioFrameCount(captureBuffer.frameCount)
              ),
              let source = capturePCMBuffer.floatChannelData?.pointee else {
            throw TranscriptionError.malformedAudio(
                URL(fileURLWithPath: "<live-buffer>"),
                "capture buffer does not match the prepared mono PCM format"
            )
        }
        let sourceByteCount = captureBuffer.frameCount * MemoryLayout<Float>.size
        try captureBuffer.pcmData.withUnsafeBytes { rawBuffer in
            guard rawBuffer.count >= sourceByteCount,
                  let baseAddress = rawBuffer.baseAddress else {
                throw TranscriptionError.malformedAudio(
                    URL(fileURLWithPath: "<live-buffer>"),
                    "capture buffer does not contain one Float32 sample per frame"
                )
            }
            memcpy(source, baseAddress, sourceByteCount)
        }
        capturePCMBuffer.frameLength = AVAudioFrameCount(captureBuffer.frameCount)

        let expectedFrameCount = max(
            1,
            Int(ceil(Double(captureBuffer.frameCount) * format.sampleRate / captureBuffer.sampleRate)) + 32
        )
        guard let analyzerPCMBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(expectedFrameCount)
        ) else {
            throw TranscriptionError.malformedAudio(
                URL(fileURLWithPath: "<live-buffer>"),
                "could not allocate the analyzer PCM buffer"
            )
        }

        let inputBuffer = AudioPCMBufferBox(capturePCMBuffer)
        let inputState = AudioConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(
            to: analyzerPCMBuffer,
            error: &conversionError
        ) { _, inputStatus in
            guard !inputState.supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputState.supplied = true
            inputStatus.pointee = .haveData
            return inputBuffer.buffer
        }
        guard status != .error, analyzerPCMBuffer.frameLength > 0 else {
            throw TranscriptionError.malformedAudio(
                URL(fileURLWithPath: "<live-buffer>"),
                conversionError.map(String.init(describing:)) ?? "audio format conversion failed"
            )
        }
        return analyzerPCMBuffer
    }

}
