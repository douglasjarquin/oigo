import Foundation
@_spi(Testing) import OigoCore
@_spi(Testing) import OigoInsertion
import OigoPresentation
@_spi(Testing) import OigoTranscription

@available(macOS 26.0, *)
@MainActor
enum SpeechReferenceCrossSurfaceScenario {
    static func run() async throws {
        var receipts: [SpeechReferenceReceipt] = []
        try runGesture(.hold, generation: 10, receipts: &receipts)
        try runGesture(.doubleTapLock, generation: 20, receipts: &receipts)
        let retryContext = try await runSpeechDegradation(generation: 30, receipts: &receipts)
        try runCopyOnly(retryContext, generation: 40, receipts: &receipts)
        try runCancellationBeforeRaw(generation: 50, receipts: &receipts)
        try await runCancellationAfterRaw(generation: 60, receipts: &receipts)
        receipts += try SpeechReferencePresentation.receipts(generation: 70)
        try SpeechReferenceEvidence.writeIfRequested(receipts)
    }

    private enum Gesture { case hold, doubleTapLock }

    private static func runGesture(
        _ gesture: Gesture,
        generation: UInt64,
        receipts: inout [SpeechReferenceReceipt]
    ) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = SpeechReferenceCapture()
        let coordinator = DictationCoordinator()
        let scheduler = SpeechReferenceScheduler()
        var operationError: Error?
        let bridge = GlobalShortcutOperationBridge(
            state: { coordinator.state },
            start: {
                do { _ = try coordinator.startRecording(using: capture, store: store) }
                catch { operationError = error }
            },
            stop: {
                do { _ = try coordinator.stopRecording() }
                catch { operationError = error }
            },
            clock: { scheduler.now },
            scheduler: scheduler.schedule
        )
        scheduler.set(milliseconds: 0)
        guard bridge.receive(.pressed) == .start,
              coordinator.state == .recording else {
            throw SpeechReferenceContractFailure(description: "press did not start recording")
        }
        switch gesture {
        case .hold:
            scheduler.set(milliseconds: 350)
            guard bridge.receive(.released) == .stop else {
                throw SpeechReferenceContractFailure(description: "hold release did not stop")
            }
        case .doubleTapLock:
            scheduler.set(milliseconds: 100)
            _ = bridge.receive(.released)
            scheduler.set(milliseconds: 449)
            guard bridge.receive(.pressed) == .locked else {
                throw SpeechReferenceContractFailure(description: "second tap did not lock")
            }
            scheduler.set(milliseconds: 450)
            _ = bridge.receive(.released)
            scheduler.set(milliseconds: 700)
            guard bridge.receive(.pressed) == .stop else {
                throw SpeechReferenceContractFailure(description: "locked next tap did not stop")
            }
        }
        guard operationError == nil,
              coordinator.state == .complete,
              coordinator.activeResourceCount == 0,
              !capture.isActive else {
            throw SpeechReferenceContractFailure(description: "gesture left lifecycle resources")
        }
        receipts.append(SpeechReferenceEvidence.receipt(
            scenario: gesture == .hold ? "shortcut-hold" : "shortcut-double-tap-lock",
            generation: generation,
            verdict: "PASS"
        ))
    }

    private struct RetryContext {
        let coordinator: DictationCoordinator
        let store: SessionStore
        let session: DictationSession
        let root: URL
        let insertion: InsertionService
        let targetEnvironment: SpeechReferenceTargetEnvironment
        let pasteboard: SpeechReferencePasteboard
        let eventSender: SpeechReferenceEventSender
        let target: InsertionTargetSnapshot
    }

    private static func runSpeechDegradation(
        generation: UInt64,
        receipts: inout [SpeechReferenceReceipt]
    ) async throws -> RetryContext {
        let root = try temporaryDirectory()
        var transfersRootOwnership = false
        defer {
            if !transfersRootOwnership { try? FileManager.default.removeItem(at: root) }
        }
        let store = try SessionStore(rootDirectory: root)
        let capture = SpeechReferenceCapture()
        let transcription = SpeechReferenceTranscription()
        let coordinator = DictationCoordinator()
        let targetEnvironment = SpeechReferenceTargetEnvironment()
        let pasteboard = SpeechReferencePasteboard()
        let eventSender = SpeechReferenceEventSender()
        let insertion = InsertionService(
            targetEnvironment: targetEnvironment,
            pasteboard: pasteboard,
            eventSender: eventSender
        )
        let target = insertion.captureTarget()
        var transfersTargetOwnership = false
        defer {
            if !transfersTargetOwnership {
                insertion.discardTarget(target)
            }
        }
        _ = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        transcription.degrade()
        for _ in 0..<200 where !coordinator.liveTranscriptionDegraded { await Task.yield() }
        guard coordinator.liveTranscriptionDegradation == .queueSaturated,
              coordinator.currentSession?.metadata.failureCode == .transcriptionFailed,
              coordinator.currentSession?.metadata.failureReason
                == LiveTranscriptionDegradation.queueSaturated.rawValue else {
            throw SpeechReferenceContractFailure(
                description: "coordinator did not observe live Speech degradation callback"
            )
        }
        do {
            _ = try await coordinator.stopRecordingWithTranscription()
            throw SpeechReferenceContractFailure(description: "degraded Speech reported success")
        } catch is TranscriptionError {}
        guard let failedSessionID = coordinator.currentSession?.id else {
            throw SpeechReferenceContractFailure(description: "degraded Speech lost its session identity")
        }
        let failed = try store.load(id: failedSessionID)
        guard failed.metadata.state == .failed,
              coordinator.activeResourceCount == 0,
              !capture.isActive else {
            throw SpeechReferenceContractFailure(description: "degraded Speech did not release resources")
        }
        let retried = try await coordinator.retryRecordingWithTranscription(
            for: failed,
            using: transcription,
            store: store
        )
        guard retried.metadata.state == .completed,
              retried.metadata.rawTextByteCount == 1,
              coordinator.activeResourceCount == 0 else {
            throw SpeechReferenceContractFailure(description: "saved-audio retry did not recover")
        }
        receipts.append(SpeechReferenceEvidence.receipt(
            scenario: "speech-degradation-retry",
            generation: generation,
            verdict: "OBSERVED_AND_RECOVERED"
        ))
        transfersRootOwnership = true
        transfersTargetOwnership = true
        return RetryContext(
            coordinator: coordinator,
            store: store,
            session: retried,
            root: root,
            insertion: insertion,
            targetEnvironment: targetEnvironment,
            pasteboard: pasteboard,
            eventSender: eventSender,
            target: target
        )
    }

    private static func runCopyOnly(
        _ context: RetryContext,
        generation: UInt64,
        receipts: inout [SpeechReferenceReceipt]
    ) throws {
        defer { try? FileManager.default.removeItem(at: context.root) }
        context.targetEnvironment.validations = [.safe, .applicationChanged]
        let result = context.insertion.insertRawText(
            for: context.session,
            store: context.store,
            target: context.target
        )
        guard result.outcome == .copied,
              result.reasonCode == .applicationChanged,
              context.targetEnvironment.captureCount == 1,
              context.targetEnvironment.validationCount == 2,
              context.pasteboard.writeCount == 1,
              context.eventSender.sendCount == 1,
              context.targetEnvironment.discardCount == 1,
              context.coordinator.activeResourceCount == 0 else {
            throw SpeechReferenceContractFailure(
                description: "joined insertion did not validate, revalidate, copy safely, and release target ownership"
            )
        }
        receipts.append(SpeechReferenceEvidence.receipt(
            scenario: "copy-only-insertion",
            generation: generation,
            verdict: "COPY_ONLY"
        ))
    }

    private static func runCancellationBeforeRaw(
        generation: UInt64,
        receipts: inout [SpeechReferenceReceipt]
    ) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = SpeechReferenceCapture()
        let coordinator = DictationCoordinator()
        _ = try coordinator.startRecording(using: capture, store: store)
        let cancelled = try coordinator.cancelRecording()
        guard cancelled.metadata.rawTextByteCount == nil,
              coordinator.activeResourceCount == 0,
              !capture.isActive else {
            throw SpeechReferenceContractFailure(description: "pre-raw cancellation leaked resources")
        }
        receipts.append(SpeechReferenceEvidence.receipt(
            scenario: "cancel-before-durable-raw",
            generation: generation,
            verdict: "CANCELLED"
        ))
    }

    private static func runCancellationAfterRaw(
        generation: UInt64,
        receipts: inout [SpeechReferenceReceipt]
    ) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = SpeechReferenceCapture()
        let transcription = SpeechReferenceTranscription()
        let coordinator = DictationCoordinator()
        _ = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        let completed = try await coordinator.stopRecordingWithTranscription()
        _ = try coordinator.beginInsertion(using: store, requiresCleanup: false)
        await coordinator.cancelActiveWork()
        let retained = try store.load(id: completed.id)
        guard retained.metadata.rawTextByteCount == 1,
              coordinator.state == .complete,
              coordinator.activeResourceCount == 0 else {
            throw SpeechReferenceContractFailure(description: "post-raw cancellation lost recovery or resources")
        }
        receipts.append(SpeechReferenceEvidence.receipt(
            scenario: "cancel-after-durable-raw",
            generation: generation,
            verdict: "CANCELLED"
        ))
    }

    private static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-speech-reference-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
