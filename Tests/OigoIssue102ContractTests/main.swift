import Darwin
import Foundation
@_spi(Testing) import OigoCore

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@MainActor
private struct OigoIssue102ContractTests {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("instant start cannot become clean", testInstantStartCannotBecomeClean),
            ("locale A cannot finalize under locale B", testLocaleACannotFinalizeUnderLocaleB),
            ("settings change does not replace owned resources", testSettingsChangeDoesNotReplaceOwnedResources),
            ("older sessions load as unknown", testOlderSessionsLoadAsUnknown),
            ("retry defaults to recorded configuration", testRetryDefaultsToRecordedConfiguration),
            ("retry override is explicit and recorded", testRetryOverrideIsRecorded),
            ("snapshot persists before first buffer", testSnapshotPersistsBeforeFirstBuffer),
            ("hotkey during retry is busy", testHotkeyDuringRetryIsBusy),
            ("stale task completion is ignored", testStaleTaskCompletionIsIgnored),
            ("quit deadline returns without waiting forever", testQuitDeadlineReturns),
            ("late child cannot mutate after quit fence", testLateChildCannotMutateAfterQuitFence),
            ("insertion success releases store references", testInsertionSuccessReleasesStore),
            ("insertion failure releases store references", testInsertionFailureReleasesStore),
            ("one hundred mixed operations stay bounded", testOneHundredMixedOperationsStayBounded)
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try await test()
                print("GREEN: " + name)
            } catch {
                failures += 1
                print("FAIL: " + name + ": " + String(describing: error))
            }
        }

        if failures == 0 {
            print("GREEN: all issue #102/#106 contract scenarios")
            exit(0)
        }
        print("FAILURES=" + String(failures))
        exit(1)
    }

    private static func testInstantStartCannotBecomeClean() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController(text: "hello")
        let coordinator = DictationCoordinator()
        let started = DictationConfigurationSnapshot.testing(mode: .instant, locale: "en-US")
        _ = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
            configuration: started
        )
        let mutatedSettings = OigoSettings.default.with(defaultMode: .clean)
        guard mutatedSettings.defaultMode == .clean,
              coordinator.activeConfiguration?.processingMode == .instant else {
            throw ContractFailure(message: "settings mutation leaked into the active snapshot")
        }
        _ = try await coordinator.stopRecordingWithTranscription()
        _ = try coordinator.beginInsertion(using: store)
        guard coordinator.state == .inserting,
              coordinator.activeConfiguration?.processingMode == .instant else {
            throw ContractFailure(message: "instant start entered cleanup because later settings were clean")
        }
        _ = try coordinator.finishInsertion(outcome: .copied)
        let saved = try store.load(id: coordinator.currentSession!.id)
        guard saved.metadata.configurationSnapshot?.processingMode == .instant,
              saved.metadata.configurationIdentity.historyLabel.contains("Instant") else {
            throw ContractFailure(message: "completed session did not keep the start-time Instant snapshot")
        }
    }

    private static func testLocaleACannotFinalizeUnderLocaleB() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController(text: "bonjour", locale: "fr-FR")
        let coordinator = DictationCoordinator()
        let started = DictationConfigurationSnapshot.testing(mode: .instant, locale: "fr-FR")
        _ = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
            configuration: started
        )
        let later = DictationConfigurationSnapshot.testing(mode: .instant, locale: "en-US")
        guard coordinator.activeConfiguration?.resolvedLocaleIdentifier == "fr-FR",
              later.resolvedLocaleIdentifier == "en-US",
              coordinator.activeTranscriptionObjectIdentifier == ObjectIdentifier(transcription) else {
            throw ContractFailure(message: "locale B replaced the locale A transcription object")
        }
        _ = try await coordinator.stopRecordingWithTranscription()
        let saved = try store.load(id: coordinator.currentSession!.id)
        guard saved.metadata.configurationSnapshot?.resolvedLocaleIdentifier == "fr-FR" else {
            throw ContractFailure(message: "finalization recorded locale B instead of locale A")
        }
    }

    private static func testSettingsChangeDoesNotReplaceOwnedResources() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController(text: "owned")
        let coordinator = DictationCoordinator()
        _ = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
            configuration: .testing(mode: .instant, locale: "en-US")
        )
        let captureID = coordinator.activeCaptureObjectIdentifier
        let transcriptionID = coordinator.activeTranscriptionObjectIdentifier
        guard NextDictationSettingsPolicy.mayReplaceOwnedCapture(isOperationActive: true) == false,
              NextDictationSettingsPolicy.mayReplaceOwnedTranscription(isOperationActive: true) == false,
              NextDictationSettingsPolicy.appliesToNextDictation(isOperationActive: true),
              captureID == ObjectIdentifier(capture),
              transcriptionID == ObjectIdentifier(transcription) else {
            throw ContractFailure(message: "active capture or transcription was treated as replaceable")
        }
        _ = try await coordinator.stopRecordingWithTranscription()
    }

    private static func testOlderSessionsLoadAsUnknown() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession()
        let loaded = try store.load(id: session.id)
        guard loaded.metadata.configurationSnapshot == nil,
              loaded.metadata.configurationIdentity == .unknown,
              loaded.metadata.configurationIdentity.historyLabel == "Configuration unknown" else {
            throw ContractFailure(message: "older session without a snapshot was not labeled unknown")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var legacy = loaded.metadata
        legacy.configurationSnapshot = .testing(mode: .clean, locale: "de-DE")
        let encoded = try encoder.encode(legacy)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTripped = try decoder.decode(SessionMetadata.self, from: encoded)
        guard roundTripped.configurationSnapshot?.resolvedLocaleIdentifier == "de-DE" else {
            throw ContractFailure(message: "snapshot metadata did not round-trip")
        }

        struct LegacyMetadata: Encodable {
            let id: UUID
            let directoryName: String
            let createdAt: Date
            let updatedAt: Date
            let state: DictationSessionState
            let audioFileName: String
            let rawTextFileName: String
            let cleanTextFileName: String
        }
        let legacyJSON = try encoder.encode(
            LegacyMetadata(
                id: loaded.metadata.id,
                directoryName: loaded.metadata.directoryName,
                createdAt: loaded.metadata.createdAt,
                updatedAt: loaded.metadata.updatedAt,
                state: .completed,
                audioFileName: "audio.caf",
                rawTextFileName: "raw.txt",
                cleanTextFileName: "clean.txt"
            )
        )
        let decodedLegacy = try decoder.decode(SessionMetadata.self, from: legacyJSON)
        guard decodedLegacy.configurationIdentity == .unknown else {
            throw ContractFailure(message: "legacy metadata guessed a configuration")
        }
    }

    private static func testRetryDefaultsToRecordedConfiguration() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController(text: "retry me")
        let coordinator = DictationCoordinator()
        let original = DictationConfigurationSnapshot.testing(mode: .clean, locale: "es-ES")
        let session = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
            configuration: original
        )
        _ = try await coordinator.interruptRecordingWithTranscription(reason: "speech failed")
        let failed = try store.load(id: session.id)
        let current = DictationConfigurationSnapshot.testing(mode: .instant, locale: "en-US")
        let resolved = DictationRetryConfiguration.resolve(
            session: failed.metadata,
            explicitOverride: nil,
            currentSettingsSnapshot: current
        )
        guard resolved.overrideRecorded == false,
              resolved.snapshot.resolvedLocaleIdentifier == "es-ES" else {
            throw ContractFailure(message: "retry did not default to the recorded configuration")
        }
        let retried = try await coordinator.retryRecordingWithTranscription(
            for: failed,
            using: transcription,
            store: store
        )
        guard retried.metadata.retryOverrideSnapshot == nil,
              retried.metadata.configurationSnapshot?.resolvedLocaleIdentifier == "es-ES" else {
            throw ContractFailure(message: "default retry rewrote the original configuration identity")
        }
    }

    private static func testRetryOverrideIsRecorded() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController(text: "override")
        let coordinator = DictationCoordinator()
        let original = DictationConfigurationSnapshot.testing(mode: .instant, locale: "en-US")
        let session = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
            configuration: original
        )
        _ = try await coordinator.interruptRecordingWithTranscription(reason: "speech failed")
        let failed = try store.load(id: session.id)
        let override = DictationConfigurationSnapshot.testing(mode: .clean, locale: "fr-FR")
        let retried = try await coordinator.retryRecordingWithTranscription(
            for: failed,
            using: transcription,
            store: store,
            configurationOverride: override
        )
        guard retried.metadata.configurationSnapshot?.resolvedLocaleIdentifier == "en-US",
              retried.metadata.retryOverrideSnapshot?.resolvedLocaleIdentifier == "fr-FR" else {
            throw ContractFailure(message: "explicit retry override was not recorded beside the original snapshot")
        }
    }

    private static func testSnapshotPersistsBeforeFirstBuffer() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController(text: "buffer")
        let coordinator = DictationCoordinator()
        let snapshot = DictationConfigurationSnapshot.testing(mode: .clean, locale: "en-GB")
        let session = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 48_000, channelCount: 1),
            configuration: snapshot
        )
        let saved = try store.load(id: session.id)
        guard saved.metadata.configurationSnapshot == snapshot,
              saved.metadata.state == .recording else {
            throw ContractFailure(message: "snapshot was missing before the first accepted audio buffer")
        }
    }

    private static func testHotkeyDuringRetryIsBusy() async throws {
        let gate = AppOperationGate()
        let handle = try succeed(gate.begin(.retry))
        let start = gate.begin(.dictation)
        guard case .failure(.occupied(.retry)) = start else {
            throw ContractFailure(message: "start during retry was not a typed busy reason")
        }
        let availability = gate.availability(coordinatorState: .failed)
        guard !availability.canStartDictation,
              !availability.canPasteAgain,
              availability.busyReason == .occupied(.retry),
              availability.busyReason?.userMessage.contains("retry") == true else {
            throw ContractFailure(message: "busy retry still advertised Start or Paste Again")
        }
        gate.complete(handle)
        guard gate.isIdle else {
            throw ContractFailure(message: "retry completion did not return the gate to idle")
        }
    }

    private static func testStaleTaskCompletionIsIgnored() async throws {
        let gate = AppOperationGate()
        var staleMutated = false
        let first = try succeed(gate.beginAndRun(.pasteAgain, completes: true) {
            try? await Task.sleep(for: .milliseconds(30))
            staleMutated = true
        })
        let second = gate.preempt(.retry)
        try? await Task.sleep(for: .milliseconds(60))
        guard gate.isCurrent(second),
              !gate.isCurrent(first),
              gate.currentKind == .retry else {
            throw ContractFailure(message: "stale paste-again completion took the current retry slot")
        }
        gate.complete(second)
        guard gate.isIdle else {
            throw ContractFailure(message: "retry slot remained after explicit completion")
        }
        _ = staleMutated
    }

    private static func testQuitDeadlineReturns() async throws {
        let gate = AppOperationGate()
        _ = try succeed(gate.beginAndRun(.retry, completes: false) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
            }
            try? await Task.sleep(for: .seconds(10))
        })
        let started = DispatchTime.now()
        let outcome = await gate.finishShutdown(timeout: AppOperationTimeoutPolicy.testing.quit) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
            }
            try? await Task.sleep(for: .seconds(10))
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
        guard outcome.repliedWithinBudget,
              elapsed < 1_000_000_000,
              outcome.fencedLoserCount >= 1,
              !gate.isAcceptingCommands,
              gate.begin(.dictation).isShutdownFailure else {
            throw ContractFailure(message: "quit waited for a noncooperative child or kept accepting commands")
        }
    }

    private static func testLateChildCannotMutateAfterQuitFence() async throws {
        let gate = AppOperationGate()
        var lateMutatedCurrent = false
        _ = try succeed(gate.beginAndRun(.dictation, completes: true) {
            try? await Task.sleep(for: .milliseconds(80))
            if gate.currentKind == .dictation {
                lateMutatedCurrent = true
            }
        })
        _ = await gate.finishShutdown(timeout: AppOperationTimeoutPolicy.testing.quit) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard lateMutatedCurrent == false,
              gate.currentKind != .dictation else {
            throw ContractFailure(message: "late child mutated the current operation after quit")
        }
    }

    private static func testInsertionSuccessReleasesStore() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController(text: "inserted")
        let coordinator = DictationCoordinator()
        _ = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
            configuration: .testing()
        )
        _ = try await coordinator.stopRecordingWithTranscription()
        _ = try coordinator.beginInsertion(using: store)
        guard coordinator.activeResourceCount > 0 else {
            throw ContractFailure(message: "insertion did not take an operation-only store reference")
        }
        _ = try coordinator.finishInsertion(outcome: .pasted)
        guard coordinator.activeResourceCount == 0,
              !coordinator.hasActiveWork else {
            throw ContractFailure(message: "successful insertion leaked operation-only store references")
        }
    }

    private static func testInsertionFailureReleasesStore() async throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController(text: "failed paste")
        let coordinator = DictationCoordinator()
        _ = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
            configuration: .testing()
        )
        _ = try await coordinator.stopRecordingWithTranscription()
        _ = try coordinator.beginInsertion(using: store)
        _ = coordinator.failInsertion(reason: "paste failed")
        guard coordinator.activeResourceCount == 0,
              !coordinator.hasActiveWork else {
            throw ContractFailure(message: "failed insertion leaked operation-only store references")
        }
    }

    private static func testOneHundredMixedOperationsStayBounded() async throws {
        let gate = AppOperationGate()
        for index in 0..<100 {
            let kind: AppOperationKind = index.isMultiple(of: 2) ? .retry : .pasteAgain
            let handle = try succeed(gate.beginAndRun(kind, completes: true) {
                await Task.yield()
            })
            let rejected = gate.begin(.dictation)
            guard case .failure(.occupied(_)) = rejected else {
                throw ContractFailure(message: "mixed-operation cycle accepted overlapping work")
            }
            try? await Task.sleep(for: .milliseconds(1))
            if gate.isCurrent(handle) {
                gate.complete(handle)
            }
        }
        guard gate.isIdle,
              gate.fencedLoserCount == 0,
              gate.registryActiveCount == 0 else {
            throw ContractFailure(message: "mixed-operation cycles leaked gate or registry ownership")
        }
    }

    private static func succeed(
        _ result: Result<AppOperationHandle, AppOperationBusyReason>
    ) throws -> AppOperationHandle {
        switch result {
        case .success(let handle):
            return handle
        case .failure(let reason):
            throw ContractFailure(message: "expected to begin operation, got " + reason.userMessage)
        }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue102-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private extension Result where Success == AppOperationHandle, Failure == AppOperationBusyReason {
    var isShutdownFailure: Bool {
        if case .failure(.shutdown) = self {
            return true
        }
        return false
    }
}

private final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
    private var onFailure: (@Sendable (String) -> Void)?
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
        _ = descriptor
        self.onFailure = onFailure
        isActive = true
    }

    func stop() throws {
        isActive = false
    }

    func cancel() {
        isActive = false
    }

    func fail(_ reason: String) {
        isActive = false
        onFailure?(reason)
    }
}

private final class FakeTranscriptionController: TranscriptionController, @unchecked Sendable {
    let locale: String
    let text: String
    private var session: DictationSession?
    private var store: SessionStore?

    init(text: String, locale: String = "en-US") {
        self.text = text
        self.locale = locale
    }

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        self.session = session
        self.store = store
        _ = format
        _ = onUpdate
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        try persist()
    }

    func cancel() async throws -> TranscriptionResult? {
        try persist()
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        self.session = session
        self.store = store
        let result = try persist()
        _ = try store.update(
            session,
            state: .completed,
            rawTextByteCount: result.rawTextByteCount
        )
        return result
    }

    private func persist() throws -> TranscriptionResult {
        if let session, let store {
            _ = try store.persistRawText(text, for: session)
        }
        return TranscriptionResult(
            finalizedText: text,
            rawTextByteCount: Int64(text.utf8.count)
        )
    }
}
