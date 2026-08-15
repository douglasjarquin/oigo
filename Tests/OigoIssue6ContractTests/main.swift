import Foundation
import OigoCore
import OigoInsertion

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@MainActor
private struct OigoIssue6ContractTests {
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("insertion metadata round trip", testInsertionMetadataRoundTrip),
            ("target snapshot captures required fields", testTargetSnapshotCapturesRequiredFields),
            ("target validation compares live identity", testTargetValidationComparesLiveIdentity),
            ("secure field refuses automatic paste", testSecureFieldRefusesAutomaticPaste),
            ("changed application copies without paste", testChangedApplicationCopiesWithoutPaste),
            ("focus change at event boundary copies without paste", testFocusChangeAtEventBoundaryCopiesWithoutPaste),
            ("unsafe target validation copies without paste", testUnsafeTargetValidationCopiesWithoutPaste),
            ("clipboard write follows raw persistence", testClipboardWriteFollowsRawPersistence),
            ("one-shot insertion", testOneShotInsertion),
            ("durable insertion claim refuses restart replay", testDurableInsertionClaimRefusesRestartReplay),
            ("completion enters insertion lifecycle", testCompletionEntersInsertionLifecycle)
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
            print("GREEN: all issue #6 contract scenarios")
            exit(0)
        }

        print("FAILURES=" + String(failures))
        exit(1)
    }

    private static func testInsertionMetadataRoundTrip() throws {
        let metadata = SessionMetadata(
            id: UUID(),
            directoryName: "20260815-issue6",
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000),
            state: .completed
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let original = try JSONSerialization.jsonObject(
            with: encoder.encode(metadata)
        ) as! [String: Any]
        var withOutcome = original
        withOutcome["insertionOutcome"] = "pasted"
        let fixture = try JSONSerialization.data(withJSONObject: withOutcome, options: [.sortedKeys])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionMetadata.self, from: fixture)
        let reencoded = try JSONSerialization.jsonObject(
            with: encoder.encode(decoded)
        ) as! [String: Any]
        guard reencoded["insertionOutcome"] as? String == "pasted" else {
            throw ContractFailure(message: "session metadata discarded the persisted insertion outcome")
        }
    }

    private static func testCompletionEntersInsertionLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue6-red-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let capture = FakeAudioCapture()
        let transcription = FakeTranscriptionController()
        let coordinator = DictationCoordinator()
        _ = try await coordinator.startRecordingWithTranscription(
            using: capture,
            store: store,
            transcription: transcription,
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
        )
        transcription.finalizedText = "raw transcript"
        let completed = try await coordinator.stopRecordingWithTranscription()
        let insertion = try coordinator.beginInsertion(using: store)
        let finished = try coordinator.finishInsertion(outcome: .pasted)
        let events = coordinator.transitionHistory.map(\.event)
        guard events.contains(.finalized),
              events.contains(.cleaned),
              events.contains(.inserted),
              insertion.id == completed.id,
              finished.metadata.insertionOutcome == .pasted,
              finished.metadata.state == .completed,
              coordinator.state == .complete else {
            throw ContractFailure(message: "completed raw transcript skipped the insertion lifecycle")
        }
    }

    private static func testTargetSnapshotCapturesRequiredFields() throws {
        let expected = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field-7",
            role: "AXTextArea",
            isSecureTextField: false
        )
        let environment = FakeTargetEnvironment(snapshot: expected, validation: .safe)
        let service = InsertionService(
            targetEnvironment: environment,
            pasteboard: FakePasteboard(),
            eventSender: FakeEventSender()
        )
        guard service.captureTarget() == expected else {
            throw ContractFailure(message: "target snapshot did not retain the required frontmost and focus fields")
        }
    }

    private static func testTargetValidationComparesLiveIdentity() throws {
        let snapshot = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field-7",
            role: "AXTextArea",
            isSecureTextField: false
        )
        let sameTarget = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: "field-7",
            currentRole: "AXTextArea",
            currentIsSecureTextField: false,
            accessibilityTrusted: true
        )
        let changedApplication = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 43,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: "field-7",
            currentRole: "AXTextArea",
            currentIsSecureTextField: false,
            accessibilityTrusted: true
        )
        let changedBundle = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.other-editor",
            currentFocusedElementIdentifier: "field-7",
            currentRole: "AXTextArea",
            currentIsSecureTextField: false,
            accessibilityTrusted: true
        )
        let changedFocus = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: "field-8",
            currentRole: "AXTextArea",
            currentIsSecureTextField: false,
            accessibilityTrusted: true
        )
        let secureCurrent = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: "field-7",
            currentRole: "AXTextArea",
            currentIsSecureTextField: true,
            accessibilityTrusted: true
        )
        let inaccessible = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: "field-7",
            currentRole: "AXTextArea",
            currentIsSecureTextField: false,
            accessibilityTrusted: false
        )
        let missingFocus = TargetValidation.evaluate(
            snapshot: snapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: nil,
            currentRole: nil,
            currentIsSecureTextField: false,
            accessibilityTrusted: true
        )
        let nonEditable = TargetValidation.evaluate(
            snapshot: InsertionTargetSnapshot(
                frontmostProcessIdentifier: 42,
                bundleIdentifier: "com.example.editor",
                focusedElementIdentifier: "field-7",
                role: "AXWindow",
                isSecureTextField: false
            ),
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: "field-7",
            currentRole: "AXWindow",
            currentIsSecureTextField: false,
            accessibilityTrusted: true
        )
        let secureSnapshot = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field-7",
            role: "AXTextField",
            isSecureTextField: true
        )
        let secureSnapshotResult = TargetValidation.evaluate(
            snapshot: secureSnapshot,
            currentProcessIdentifier: 42,
            currentBundleIdentifier: "com.example.editor",
            currentFocusedElementIdentifier: "field-7",
            currentRole: "AXTextField",
            currentIsSecureTextField: false,
            accessibilityTrusted: true
        )
        guard sameTarget == .safe,
              changedApplication == .applicationChanged,
              changedBundle == .applicationChanged,
              changedFocus == .focusedElementChanged,
              secureCurrent == .secureTextField,
              inaccessible == .accessibilityUnavailable,
              missingFocus == .missingFocusedElement,
              nonEditable == .nonEditableRole,
              secureSnapshotResult == .secureTextField else {
            throw ContractFailure(message: "target validation did not compare live PID, focus, secure, and Accessibility state")
        }
    }

    private static func testSecureFieldRefusesAutomaticPaste() throws {
        let (store, session) = try persistedSession(rawText: "secret transcript")
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let target = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "password",
            role: "AXTextField",
            isSecureTextField: true
        )
        let environment = FakeTargetEnvironment(snapshot: target, validation: .secureTextField)
        let pasteboard = FakePasteboard()
        let eventSender = FakeEventSender()
        let result = InsertionService(
            targetEnvironment: environment,
            pasteboard: pasteboard,
            eventSender: eventSender
        ).insertRawText(for: session, store: store, target: target)
        guard result.outcome == .secureRejected,
              pasteboard.writes == ["secret transcript"],
              eventSender.sendCalls == 0 else {
            throw ContractFailure(message: "secure target was not copied without an automatic paste")
        }
    }

    private static func testChangedApplicationCopiesWithoutPaste() throws {
        let (store, session) = try persistedSession(rawText: "changed application transcript")
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let target = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field-7",
            role: "AXTextArea",
            isSecureTextField: false
        )
        let environment = FakeTargetEnvironment(snapshot: target, validation: .applicationChanged)
        let pasteboard = FakePasteboard()
        let eventSender = FakeEventSender()
        let result = InsertionService(
            targetEnvironment: environment,
            pasteboard: pasteboard,
            eventSender: eventSender
        ).insertRawText(for: session, store: store, target: target)
        guard result.outcome == .copied,
              pasteboard.writes == ["changed application transcript"],
              eventSender.sendCalls == 0 else {
            throw ContractFailure(message: "changed application did not produce copy-only fallback")
        }
    }

    private static func testFocusChangeAtEventBoundaryCopiesWithoutPaste() throws {
        let (store, session) = try persistedSession(rawText: "focus changed transcript")
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let target = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field-7",
            role: "AXTextArea",
            isSecureTextField: false
        )
        let environment = FakeTargetEnvironment(
            snapshot: target,
            validations: [.safe, .focusedElementChanged]
        )
        let pasteboard = FakePasteboard()
        let eventSender = FakeEventSender()
        let result = InsertionService(
            targetEnvironment: environment,
            pasteboard: pasteboard,
            eventSender: eventSender
        ).insertRawText(for: session, store: store, target: target)
        guard result.outcome == .copied,
              environment.validationCalls == 2,
              eventSender.sendCalls == 0 else {
            throw ContractFailure(message: "focus changed after initial validation but Command-V was still sent")
        }
    }

    private static func testUnsafeTargetValidationCopiesWithoutPaste() throws {
        let validations: [TargetValidation] = [
            .accessibilityUnavailable,
            .applicationChanged,
            .focusedElementChanged,
            .missingFocusedElement,
            .nonEditableRole
        ]
        let target = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field-7",
            role: "AXTextArea",
            isSecureTextField: false
        )

        for validation in validations {
            let rawText = String(describing: validation)
            let (store, session) = try persistedSession(rawText: rawText)
            defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
            let pasteboard = FakePasteboard()
            let eventSender = FakeEventSender()
            let result = InsertionService(
                targetEnvironment: FakeTargetEnvironment(snapshot: target, validation: validation),
                pasteboard: pasteboard,
                eventSender: eventSender
            ).insertRawText(for: session, store: store, target: target)
            guard result.outcome == .copied,
                  pasteboard.currentText == rawText,
                  eventSender.sendCalls == 0 else {
                throw ContractFailure(
                    message: "unsafe validation " + rawText + " did not produce copy-only fallback"
                )
            }
        }
    }

    private static func testClipboardWriteFollowsRawPersistence() throws {
        let (store, session) = try persistedSession(rawText: "persisted before clipboard")
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let target = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field-7",
            role: "AXTextArea",
            isSecureTextField: false
        )
        let environment = FakeTargetEnvironment(snapshot: target, validation: .safe)
        let pasteboard = FakePasteboard()
        var sawPersistedRawText = false
        pasteboard.onWrite = { text in
            let persisted = try? String(contentsOf: session.rawTextURL, encoding: .utf8)
            sawPersistedRawText = persisted == text
            return sawPersistedRawText
        }
        let result = InsertionService(
            targetEnvironment: environment,
            pasteboard: pasteboard,
            eventSender: FakeEventSender()
        ).insertRawText(for: session, store: store, target: target)
        guard result.outcome == .pasted, sawPersistedRawText else {
            throw ContractFailure(message: "clipboard write did not observe the persisted raw transcript")
        }
    }

    private static func testOneShotInsertion() throws {
        let (store, session) = try persistedSession(rawText: "one shot transcript")
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let (secondStore, secondSession) = try persistedSession(rawText: "next session transcript")
        defer { try? FileManager.default.removeItem(at: secondStore.rootDirectory) }
        let target = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field-7",
            role: "AXTextArea",
            isSecureTextField: false
        )
        let environment = FakeTargetEnvironment(snapshot: target, validation: .safe)
        let pasteboard = FakePasteboard()
        let eventSender = FakeEventSender()
        let service = InsertionService(
            targetEnvironment: environment,
            pasteboard: pasteboard,
            eventSender: eventSender
        )
        let first = service.insertRawText(for: session, store: store, target: target)
        let second = service.insertRawText(for: session, store: store, target: target)
        _ = try store.update(
            session,
            state: .completed,
            insertionOutcome: .pasted
        )
        let persistedRetry = InsertionService(
            targetEnvironment: environment,
            pasteboard: pasteboard,
            eventSender: eventSender
        ).insertRawText(for: session, store: store, target: target)
        let next = service.insertRawText(for: secondSession, store: secondStore, target: target)
        guard first.outcome == .pasted,
              second.outcome == .failed,
              persistedRetry.outcome == .failed,
              next.outcome == .pasted,
              pasteboard.writes == ["one shot transcript", "next session transcript"],
              eventSender.sendCalls == 2 else {
            throw ContractFailure(message: "duplicate completion attempted more than one insertion")
        }
    }

    private static func testDurableInsertionClaimRefusesRestartReplay() throws {
        let (store, session) = try persistedSession(rawText: "claimed transcript")
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        _ = try store.claimInsertion(for: session)
        let target = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field-7",
            role: "AXTextArea",
            isSecureTextField: false
        )
        let pasteboard = FakePasteboard()
        let eventSender = FakeEventSender()
        let result = InsertionService(
            targetEnvironment: FakeTargetEnvironment(snapshot: target, validation: .safe),
            pasteboard: pasteboard,
            eventSender: eventSender
        ).insertRawText(for: session, store: store, target: target)
        guard result.outcome == .failed,
              pasteboard.writes.isEmpty,
              eventSender.sendCalls == 0 else {
            throw ContractFailure(message: "a persisted insertion claim did not prevent a restart replay")
        }
    }

    private static func persistedSession(rawText: String) throws -> (SessionStore, DictationSession) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue6-insertion-" + UUID().uuidString, isDirectory: true)
        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession()
        let persisted = try store.persistRawText(rawText, for: session)
        return (store, persisted)
    }
}

@MainActor
private final class FakeTargetEnvironment: InsertionTargetEnvironment {
    let snapshot: InsertionTargetSnapshot
    private var validations: [TargetValidation]
    private(set) var validationCalls = 0

    init(snapshot: InsertionTargetSnapshot, validation: TargetValidation) {
        self.snapshot = snapshot
        validations = [validation]
    }

    init(snapshot: InsertionTargetSnapshot, validations: [TargetValidation]) {
        self.snapshot = snapshot
        self.validations = validations
    }

    func capture() -> InsertionTargetSnapshot {
        snapshot
    }

    func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation {
        _ = snapshot
        validationCalls += 1
        return validations[min(validationCalls - 1, validations.count - 1)]
    }
}

@MainActor
private final class FakePasteboard: InsertionPasteboard {
    private(set) var writes: [String] = []
    private(set) var currentText = "previous clipboard"
    var onWrite: ((String) -> Bool)?
    var writeResult = true

    func write(_ rawText: String) -> Bool {
        writes.append(rawText)
        currentText = rawText
        return onWrite?(rawText) ?? writeResult
    }
}

@MainActor
private final class FakeEventSender: InsertionEventSender {
    private(set) var sendCalls = 0

    func sendPaste(
        to processIdentifier: Int32,
        revalidate: () -> TargetValidation
    ) -> InsertionEventResult {
        _ = processIdentifier
        let validation = revalidate()
        guard validation == .safe else {
            return .targetUnsafe(validation)
        }
        sendCalls += 1
        return .sent
    }
}

private final class FakeAudioCapture: AudioCapturing, @unchecked Sendable {
    private(set) var isActive = false

    func start(
        to descriptor: AudioFileDescriptor,
        onBuffer: @escaping @Sendable (AudioCaptureBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onInterruption: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) throws {
        _ = descriptor
        _ = onBuffer
        _ = onFinish
        _ = onInterruption
        _ = onFailure
        isActive = true
    }

    func stop() throws {
        isActive = false
    }

    func cancel() {
        isActive = false
    }
}

private final class FakeTranscriptionController: TranscriptionController, @unchecked Sendable {
    var finalizedText = ""
    private(set) var isRunning = false
    private var session: DictationSession?
    private var store: SessionStore?

    func start(
        session: DictationSession,
        format: AudioCaptureFormat,
        store: SessionStore,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws {
        self.session = session
        _ = format
        self.store = store
        _ = onUpdate
        isRunning = true
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        isRunning = false
        if let session, let store {
            _ = try store.persistRawText(finalizedText, for: session)
        }
        return TranscriptionResult(
            finalizedText: finalizedText,
            rawTextByteCount: Int64(finalizedText.utf8.count)
        )
    }

    func cancel() async throws -> TranscriptionResult? {
        isRunning = false
        if let session, let store {
            _ = try store.persistRawText(finalizedText, for: session)
        }
        return TranscriptionResult(
            finalizedText: finalizedText,
            rawTextByteCount: Int64(finalizedText.utf8.count)
        )
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        _ = session
        _ = store
        return TranscriptionResult(finalizedText: finalizedText, rawTextByteCount: 0)
    }
}
