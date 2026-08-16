import Foundation
import Darwin
@_spi(Testing) import OigoCore
import OigoInsertion
@_spi(Testing) import OigoTranscription

private struct ContractFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

@main
@available(macOS 26.0, *)
@MainActor
private struct OigoIssue7ContractTests {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let filter: String? = if let index = arguments.firstIndex(of: "--filter"),
                                  arguments.indices.contains(index + 1) {
            arguments[index + 1]
        } else {
            nil
        }
        let normalizedFilter = filter?.replacingOccurrences(of: "-", with: " ")
        let tests: [(String, () async throws -> Void)] = [
            ("interrupted discovery isolates malformed sessions", testInterruptedDiscoveryIsolatesMalformedSessions),
            ("active deletion is refused", testActiveDeletionIsRefused),
            ("history metadata is bounded and malformed sessions are isolated", testHistoryMetadataIsBounded),
            ("retry transition preserves durable audio", testRetryTransitionPreservesDurableAudio),
            ("retention boundaries are explicit and safe", testRetentionBoundaries),
            ("deletion removes all session artifacts", testDeletionRemovesAllSessionArtifacts),
            ("paste again recovers a failed insertion", testPasteAgainRecoversFailedInsertion)
        ]

        var failures = 0
        var matched = 0
        for (name, test) in tests where normalizedFilter == nil || name.contains(normalizedFilter ?? "") {
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
            print("FAIL: no issue #7 contract scenarios matched filter")
            exit(1)
        }
        if failures == 0 {
            print("GREEN: all issue #7 contract scenarios")
            exit(0)
        }
        print("FAILURES=" + String(failures))
        exit(1)
    }

    private static func testInterruptedDiscoveryIsolatesMalformedSessions() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        var active = try store.createSession(now: Date(timeIntervalSince1970: 10_000))
        active = try store.update(
            active,
            state: .recording,
            at: Date(timeIntervalSince1970: 10_001)
        )
        try Data([0x43, 0x41, 0x46]).write(to: active.audioURL, options: [.atomic])

        let malformed = root.appendingPathComponent("20260815-malformed", isDirectory: true)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: false)
        try Data("not-json".utf8).write(
            to: malformed.appendingPathComponent("session.json"),
            options: [.atomic]
        )

        let recovered: [DictationSession]
        do {
            recovered = try store.recoverUnfinishedSessions(at: Date(timeIntervalSince1970: 10_100))
        } catch {
            throw ContractFailure(
                message: "malformed sibling prevented valid interrupted-session recovery: " + String(describing: error)
            )
        }
        guard recovered.count == 1,
              recovered[0].id == active.id,
              recovered[0].metadata.state == .interrupted,
              FileManager.default.fileExists(atPath: active.audioURL.path) else {
            throw ContractFailure(message: "valid active session was not recovered while malformed sibling was isolated")
        }
    }

    private static func testActiveDeletionIsRefused() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        var active = try store.createSession(now: Date(timeIntervalSince1970: 11_000))
        active = try store.update(active, state: .recording, at: Date(timeIntervalSince1970: 11_001))

        do {
            try store.remove(id: active.id)
            throw ContractFailure(message: "active session was deleted instead of being retained")
        } catch let error as ContractFailure {
            throw error
        } catch let error as SessionStoreError {
            guard error.description.contains("active") else {
                throw ContractFailure(message: "active deletion returned a non-actionable error: " + error.description)
            }
        }

        guard FileManager.default.fileExists(atPath: active.directoryURL.path) else {
            throw ContractFailure(message: "active session directory disappeared after refused deletion")
        }

        let preparing = try store.createSession(now: Date(timeIntervalSince1970: 11_002))
        try Data([0x50, 0x52, 0x45, 0x50]).write(to: preparing.audioURL, options: [.atomic])
        do {
            try store.remove(id: preparing.id)
            throw ContractFailure(message: "preparing session with durable audio was deleted")
        } catch let error as ContractFailure {
            throw error
        } catch let error as SessionStoreError {
            guard error.description.contains("active") else {
                throw ContractFailure(message: "preparing session deletion returned a non-active error: " + error.description)
            }
        }

        let mismatched = try store.createSession(now: Date(timeIntervalSince1970: 11_003))
        let mismatchedData = try Data(contentsOf: mismatched.metadataURL)
        guard var mismatchedObject = try JSONSerialization.jsonObject(
            with: mismatchedData
        ) as? [String: Any] else {
            throw ContractFailure(message: "could not build the mismatched metadata fixture")
        }
        mismatchedObject["id"] = UUID().uuidString
        let rewrittenMetadata = try JSONSerialization.data(
            withJSONObject: mismatchedObject,
            options: [.sortedKeys]
        )
        try rewrittenMetadata.write(to: mismatched.metadataURL, options: [.atomic])
        do {
            _ = try store.load(id: mismatched.id)
            throw ContractFailure(message: "session lookup accepted a directory and metadata UUID mismatch")
        } catch let error as SessionStoreError {
            guard case .invalidMetadata = error else {
                throw ContractFailure(message: "UUID-mismatched session returned the wrong error: " + error.description)
            }
        }
    }

    private static func testHistoryMetadataIsBounded() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let older = try store.createSession(now: Date(timeIntervalSince1970: 12_000))
        let olderCompleted = try store.persistRawText(
            "older first line\nfull older transcript",
            for: older
        )
        _ = try store.update(
            olderCompleted,
            state: .completed,
            at: Date(timeIntervalSince1970: 12_001)
        )

        let newest = try store.createSession(now: Date(timeIntervalSince1970: 12_002))
        let newestCompleted = try store.persistRawText(
            "newest first line\n" + String(repeating: "body ", count: 20_000),
            for: newest
        )
        try Data("processed transcript".utf8).write(to: newest.cleanTextURL, options: [.atomic])
        _ = try store.update(
            newestCompleted,
            state: .completed,
            at: Date(timeIntervalSince1970: 12_003)
        )

        let malformed = root.appendingPathComponent("20260815-history-malformed", isDirectory: true)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: false)
        try Data("broken".utf8).write(
            to: malformed.appendingPathComponent("session.json"),
            options: [.atomic]
        )

        let listedSessions = try store.listSessions()
        guard listedSessions.contains(where: { $0.id == older.id }),
              !listedSessions.contains(where: { $0.directoryURL == malformed }) else {
            throw ContractFailure(message: "strict session listing did not isolate malformed metadata")
        }

        let fifoSession = try store.createSession(now: Date(timeIntervalSince1970: 11_999))
        let fifoCompleted = try store.update(
            fifoSession,
            state: .completed,
            at: Date(timeIntervalSince1970: 12_000)
        )
        let fifoResult = fifoCompleted.rawTextURL.path.withCString { path in
            Darwin.mkfifo(path, mode_t(0o600))
        }
        guard fifoResult == 0 else {
            throw ContractFailure(message: "could not create the non-regular transcript fixture")
        }

        let fifoHistory = try store.listHistory(limit: 10).first { entry in
            entry.id == fifoCompleted.id
        }
        guard fifoHistory?.firstTranscriptLine == nil else {
            throw ContractFailure(message: "history read a non-regular transcript artifact")
        }

        let newestOnly = try store.listHistory(limit: 1)
        guard newestOnly.count == 1,
              newestOnly[0].id == newest.id,
              newestOnly[0].firstTranscriptLine == "newest first line",
              newestOnly[0].textSource == .processed,
              newestOnly[0].session.metadata.rawTextByteCount == Int64(
                Data(("newest first line\n" + String(repeating: "body ", count: 20_000)).utf8).count
              ) else {
            throw ContractFailure(message: "history did not return bounded newest metadata with the correct source and first line")
        }

        let history = try store.listHistory(limit: 10)
        guard history.map(\.id) == [newest.id, older.id, fifoCompleted.id] else {
            throw ContractFailure(message: "one malformed session prevented valid history entries from loading")
        }

        let oversized = try store.createSession(now: Date(timeIntervalSince1970: 12_004))
        _ = try store.persistRawText(
            String(repeating: "x", count: 4 * 1024 * 1024 + 1),
            for: oversized
        )
        do {
            _ = try store.readRawText(for: oversized)
            throw ContractFailure(message: "oversized transcript was loaded without a read bound")
        } catch let error as SessionStoreError {
            guard case .transcriptTooLarge = error else {
                throw ContractFailure(message: "oversized transcript returned the wrong error: " + error.description)
            }
        }
    }

    private static func testRetryTransitionPreservesDurableAudio() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let created = try store.createSession(now: Date(timeIntervalSince1970: 13_000))
        let failed = try store.update(
            created,
            state: .failed,
            at: Date(timeIntervalSince1970: 13_001),
            failureReason: "analysis failed"
        )
        let originalAudio = Data([0x43, 0x41, 0x46, 0x2D, 0x53, 0x4F, 0x55, 0x52, 0x43, 0x45])
        try originalAudio.write(to: failed.audioURL, options: [.atomic])

        let retrying = try store.beginTranscriptionRetry(
            for: failed,
            at: Date(timeIntervalSince1970: 13_002)
        )
        guard retrying.metadata.state == .retrying,
              retrying.metadata.transcriptionAttemptCount == 1 else {
            throw ContractFailure(message: "retry did not persist an active processing attempt")
        }

        let consumed = try SavedAudioRetry.retry(
            session: retrying,
            store: store,
            liveFailure: TranscriptionError.analysisFailed("fixture")
        ) { descriptor in
            let descriptorURL = URL(fileURLWithPath: "/dev/fd/\(descriptor.rawValue)")
            return try Data(contentsOf: descriptorURL)
        }
        guard consumed == originalAudio,
              try Data(contentsOf: retrying.audioURL) == originalAudio else {
            throw ContractFailure(message: "retry did not consume and preserve the durable source audio")
        }

        let failedAgain = try store.update(
            retrying,
            state: .failed,
            at: Date(timeIntervalSince1970: 13_002.5),
            failureReason: "second analysis failed"
        )
        let retryingAgain = try store.beginTranscriptionRetry(
            for: failedAgain,
            at: Date(timeIntervalSince1970: 13_002.75)
        )
        guard retryingAgain.metadata.transcriptionAttemptCount == 2 else {
            throw ContractFailure(message: "a failed retry did not remain eligible for a later retry")
        }
        let retried = try store.persistRawText("retried transcript", for: retryingAgain)
        let completed = try store.update(
            retried,
            state: .completed,
            at: Date(timeIntervalSince1970: 13_003),
            audioByteCount: Int64(originalAudio.count),
            rawTextByteCount: Int64("retried transcript".utf8.count)
        )
        guard completed.metadata.state == .completed,
              completed.metadata.transcriptionAttemptCount == 2,
              try Data(contentsOf: completed.audioURL) == originalAudio else {
            throw ContractFailure(message: "successful retry did not complete the same session without replacing audio")
        }

        let coordinatorSession = try store.createSession(now: Date(timeIntervalSince1970: 13_010))
        let coordinatorFailed = try store.update(
            coordinatorSession,
            state: .failed,
            at: Date(timeIntervalSince1970: 13_011),
            failureReason: "coordinator fixture"
        )
        try originalAudio.write(to: coordinatorFailed.audioURL, options: [.atomic])
        let coordinator = DictationCoordinator(initialState: .complete)
        let coordinatorRetry = Issue7RetryTranscription(finalizedText: "coordinator retry")
        let coordinatorCompleted = try await coordinator.retryRecordingWithTranscription(
            for: coordinatorFailed,
            using: coordinatorRetry,
            store: store
        )
        guard coordinatorCompleted.metadata.state == .completed,
              coordinator.state == .complete,
              try Data(contentsOf: coordinatorCompleted.audioURL) == originalAudio else {
            throw ContractFailure(message: "history retry was unavailable after a completed dictation")
        }

        let timedCreated = try store.createSession(now: Date(timeIntervalSince1970: 13_020))
        let timedRecording = try store.update(
            timedCreated,
            state: .recording,
            at: Date(timeIntervalSince1970: 13_021)
        )
        let timedFailed = try store.update(
            timedRecording,
            state: .failed,
            at: Date(timeIntervalSince1970: 13_025),
            failureReason: "duration fixture"
        )
        let timedAgain = try store.update(
            timedFailed,
            state: .failed,
            at: Date(timeIntervalSince1970: 14_000),
            insertionOutcome: .failed,
            insertionFailureReason: "still unavailable"
        )
        guard timedFailed.metadata.duration == 4,
              timedAgain.metadata.duration == timedFailed.metadata.duration else {
            throw ContractFailure(message: "terminal metadata updates changed the recording duration")
        }
    }

    private static func testRetentionBoundaries() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let base = Date(timeIntervalSince1970: 20_000)
        var sessions: [DictationSession] = []
        for index in 0..<101 {
            let created = try store.createSession(now: base.addingTimeInterval(Double(index)))
            let persisted = try store.persistRawText("transcript \(index)", for: created)
            let completed = try store.update(
                persisted,
                state: .completed,
                at: base.addingTimeInterval(Double(index))
            )
            try Data([0x43, 0x41, 0x46]).write(to: completed.audioURL, options: [.atomic])
            sessions.append(completed)
        }

        let retentionResult = try store.performIdleMaintenance(
            at: base.addingTimeInterval(101),
            policy: SessionRetentionPolicy(
                maxTranscriptSessions: 100,
                successfulAudioLifetime: 365 * 24 * 60 * 60
            )
        )
        guard retentionResult.removedSessionIDs.isEmpty,
              (try? store.load(id: sessions[0].id)) != nil,
              !FileManager.default.fileExists(atPath: sessions[0].rawTextURL.path),
              FileManager.default.fileExists(atPath: sessions[0].audioURL.path),
              FileManager.default.fileExists(atPath: sessions[1].rawTextURL.path) else {
            throw ContractFailure(message: "transcript retention did not prune old text while preserving fresh successful audio")
        }

        let zeroRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: zeroRoot) }
        let zeroStore = try SessionStore(rootDirectory: zeroRoot)
        let zeroCreated = try zeroStore.createSession(now: base)
        let zeroTranscript = try zeroStore.persistRawText("zero retention", for: zeroCreated)
        let zeroCompleted = try zeroStore.update(zeroTranscript, state: .completed, at: base)
        let zeroResult = try zeroStore.performIdleMaintenance(
            at: base.addingTimeInterval(1),
            policy: SessionRetentionPolicy(
                maxTranscriptSessions: 0,
                successfulAudioLifetime: 365 * 24 * 60 * 60
            )
        )
        guard zeroResult.removedSessionIDs == [zeroCompleted.id],
              (try? zeroStore.load(id: zeroCompleted.id)) == nil else {
            throw ContractFailure(message: "zero transcript retention did not remove the oldest transcript session")
        }

        let boundaryRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: boundaryRoot) }
        let boundaryStore = try SessionStore(rootDirectory: boundaryRoot)
        let exactCreated = try boundaryStore.createSession(now: base)
        let exactPersisted = try boundaryStore.persistRawText("exact boundary", for: exactCreated)
        let exact = try boundaryStore.update(
            exactPersisted,
            state: .completed,
            at: base
        )
        try Data([0x43, 0x41, 0x46]).write(to: exact.audioURL, options: [.atomic])
        _ = try boundaryStore.performIdleMaintenance(
            at: base.addingTimeInterval(24 * 60 * 60),
            policy: SessionRetentionPolicy(maxTranscriptSessions: 100)
        )
        guard FileManager.default.fileExists(atPath: exact.audioURL.path) else {
            throw ContractFailure(message: "successful audio was deleted at the exact 24-hour boundary")
        }
        let afterBoundary = try boundaryStore.performIdleMaintenance(
            at: base.addingTimeInterval(24 * 60 * 60 + 1),
            policy: SessionRetentionPolicy(maxTranscriptSessions: 100)
        )
        guard afterBoundary.removedAudioSessionIDs == [exact.id],
              !FileManager.default.fileExists(atPath: exact.audioURL.path) else {
            throw ContractFailure(message: "successful audio older than 24 hours was not removed during idle maintenance")
        }

        let audioOnlyRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: audioOnlyRoot) }
        let audioOnlyStore = try SessionStore(rootDirectory: audioOnlyRoot)
        let audioOnlyCreated = try audioOnlyStore.createSession(now: base)
        let audioOnly = try audioOnlyStore.update(
            audioOnlyCreated,
            state: .completed,
            at: base
        )
        try Data([0x41, 0x55, 0x44, 0x49, 0x4F]).write(to: audioOnly.audioURL, options: [.atomic])
        _ = try audioOnlyStore.performIdleMaintenance(
            at: base.addingTimeInterval(24 * 60 * 60),
            policy: SessionRetentionPolicy(maxTranscriptSessions: 0)
        )
        guard FileManager.default.fileExists(atPath: audioOnly.audioURL.path) else {
            throw ContractFailure(message: "successful audio-only session was deleted at the exact 24-hour boundary")
        }
        let audioOnlyAfterBoundary = try audioOnlyStore.performIdleMaintenance(
            at: base.addingTimeInterval(24 * 60 * 60 + 1),
            policy: SessionRetentionPolicy(maxTranscriptSessions: 0)
        )
        guard audioOnlyAfterBoundary.removedSessionIDs == [audioOnly.id],
              !FileManager.default.fileExists(atPath: audioOnly.directoryURL.path) else {
            throw ContractFailure(message: "expired audio-only session was not removed after its retention boundary")
        }

        let prunedRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: prunedRoot) }
        let prunedStore = try SessionStore(rootDirectory: prunedRoot)
        let prunedCreated = try prunedStore.createSession(now: base)
        let prunedPersisted = try prunedStore.persistRawText("prune transcript", for: prunedCreated)
        let pruned = try prunedStore.update(prunedPersisted, state: .completed, at: base)
        try Data([0x50, 0x52, 0x55, 0x4E, 0x45]).write(to: pruned.audioURL, options: [.atomic])
        prunedStore.failNextMetadataWriteForTesting()
        var faultWasObserved = false
        do {
            _ = try prunedStore.performIdleMaintenance(
                at: base.addingTimeInterval(1),
                policy: SessionRetentionPolicy(maxTranscriptSessions: 0)
            )
        } catch {
            faultWasObserved = true
        }
        guard faultWasObserved else {
            throw ContractFailure(message: "transcript pruning did not expose the injected metadata-write fault")
        }
        let recoveredPruned = try prunedStore.load(id: pruned.id)
        guard FileManager.default.fileExists(atPath: recoveredPruned.rawTextURL.path),
              try prunedStore.readRawText(for: recoveredPruned) == "prune transcript" else {
            throw ContractFailure(message: "transcript pruning did not recover the original files after a metadata fault")
        }
        _ = try prunedStore.performIdleMaintenance(
            at: base.addingTimeInterval(1),
            policy: SessionRetentionPolicy(maxTranscriptSessions: 0)
        )
        guard FileManager.default.fileExists(atPath: pruned.audioURL.path),
              !FileManager.default.fileExists(atPath: pruned.rawTextURL.path),
              (try? prunedStore.load(id: pruned.id)) != nil else {
            throw ContractFailure(message: "transcript pruning removed successful audio before its retention boundary")
        }

        let overflowRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: overflowRoot) }
        let overflowStore = try SessionStore(rootDirectory: overflowRoot)
        var oldestOverflowID: UUID?
        for index in 0...4_096 {
            let created = try overflowStore.createSession(
                now: base.addingTimeInterval(Double(index))
            )
            let cancelled = try overflowStore.update(
                created,
                state: .cancelled,
                at: base.addingTimeInterval(Double(index))
            )
            if index == 0 {
                oldestOverflowID = cancelled.id
            }
        }
        let overflowResult = try overflowStore.performIdleMaintenance(
            at: base.addingTimeInterval(10_000),
            policy: SessionRetentionPolicy(maxTranscriptSessions: 100)
        )
        guard let oldestOverflowID,
              (try? overflowStore.load(id: oldestOverflowID)) == nil,
              overflowResult.removedSessionIDs.count == 4_097 else {
            throw ContractFailure(message: "idle retention stopped at the directory inspection bound")
        }

        let protectedRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: protectedRoot) }
        let protectedStore = try SessionStore(rootDirectory: protectedRoot)
        let failed = try protectedStore.createSession(now: base)
        let failedSession = try protectedStore.update(
            failed,
            state: .failed,
            at: base,
            failureReason: "recover me"
        )
        try Data([0x46, 0x41, 0x49, 0x4C]).write(to: failedSession.audioURL, options: [.atomic])
        let interrupted = try protectedStore.createSession(now: base.addingTimeInterval(1))
        let interruptedSession = try protectedStore.update(
            interrupted,
            state: .interrupted,
            at: base.addingTimeInterval(1),
            failureReason: "interrupted"
        )
        try Data([0x49, 0x4E, 0x54]).write(to: interruptedSession.audioURL, options: [.atomic])
        let active = try protectedStore.createSession(now: base.addingTimeInterval(2))
        let activeSession = try protectedStore.update(
            active,
            state: .recording,
            at: base.addingTimeInterval(2)
        )
        try Data([0x41, 0x43, 0x54]).write(to: activeSession.audioURL, options: [.atomic])
        let cancelled = try protectedStore.createSession(now: base.addingTimeInterval(3))
        let cancelledSession = try protectedStore.update(
            cancelled,
            state: .cancelled,
            at: base.addingTimeInterval(3)
        )
        let protectedResult = try protectedStore.performIdleMaintenance(
            at: base.addingTimeInterval(365 * 24 * 60 * 60),
            policy: SessionRetentionPolicy(maxTranscriptSessions: 1)
        )
        guard protectedResult.removedSessionIDs == [cancelledSession.id],
              FileManager.default.fileExists(atPath: failedSession.audioURL.path),
              FileManager.default.fileExists(atPath: interruptedSession.audioURL.path),
              FileManager.default.fileExists(atPath: activeSession.audioURL.path) else {
            throw ContractFailure(message: "retention deleted protected audio or kept an empty cancelled session")
        }
    }

    private static func testDeletionRemovesAllSessionArtifacts() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let session = try store.createSession(now: Date(timeIntervalSince1970: 14_000))
        let persisted = try store.persistRawText("delete me", for: session)
        let completed = try store.update(persisted, state: .completed)
        try Data([0x43, 0x41, 0x46]).write(to: completed.audioURL, options: [.atomic])
        try Data("processed".utf8).write(to: completed.cleanTextURL, options: [.atomic])

        try store.remove(id: completed.id)
        guard !FileManager.default.fileExists(atPath: completed.directoryURL.path),
              !FileManager.default.fileExists(atPath: completed.metadataURL.path),
              !FileManager.default.fileExists(atPath: completed.audioURL.path),
              !FileManager.default.fileExists(atPath: completed.rawTextURL.path),
              !FileManager.default.fileExists(atPath: completed.cleanTextURL.path),
              FileManager.default.fileExists(atPath: root.path) else {
            throw ContractFailure(message: "session deletion did not remove all associated artifacts atomically enough")
        }
    }

    @MainActor
    private static func testPasteAgainRecoversFailedInsertion() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SessionStore(rootDirectory: root)
        let created = try store.createSession()
        let persisted = try store.persistRawText("recover this paste", for: created)
        let completed = try store.update(persisted, state: .completed)
        let target = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            focusedElementIdentifier: "field-7",
            role: "AXTextArea",
            isSecureTextField: false
        )
        let pasteboard = Issue7Pasteboard()
        pasteboard.writeResult = false
        let sender = Issue7EventSender()
        let environment = Issue7TargetEnvironment(snapshot: target)
        let service = InsertionService(
            targetEnvironment: environment,
            pasteboard: pasteboard,
            eventSender: sender
        )

        let first = service.insertRawText(for: completed, store: store, target: target)
        let failed = try store.update(
            completed,
            state: .completed,
            insertionOutcome: first.outcome,
            insertionFailureReason: first.reason
        )
        pasteboard.writeResult = true

        let recovered = InsertionService(
            targetEnvironment: environment,
            pasteboard: pasteboard,
            eventSender: sender
        ).pasteAgain(for: failed, store: store, target: target)
        let persistedRecovery = try store.update(
            failed,
            state: .completed,
            insertionOutcome: recovered.outcome,
            insertionFailureReason: recovered.reason
        )
        let automaticReplay = InsertionService(
            targetEnvironment: environment,
            pasteboard: pasteboard,
            eventSender: sender
        ).insertRawText(for: persistedRecovery, store: store, target: target)

        guard first.outcome == .failed,
              recovered.outcome == .pasted,
              automaticReplay.outcome == .failed,
              pasteboard.writes == ["recover this paste", "recover this paste"],
              sender.sendCalls == 1,
              persistedRecovery.metadata.insertionOutcome == .pasted else {
            throw ContractFailure(message: "Paste Again did not recover the failed insertion without reopening automatic insertion")
        }
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue7-red-" + UUID().uuidString, isDirectory: true)
    }
}

@MainActor
private final class Issue7TargetEnvironment: InsertionTargetEnvironment {
    let snapshot: InsertionTargetSnapshot

    init(snapshot: InsertionTargetSnapshot) {
        self.snapshot = snapshot
    }

    func capture() -> InsertionTargetSnapshot {
        snapshot
    }

    func validate(_ snapshot: InsertionTargetSnapshot) -> TargetValidation {
        _ = snapshot
        return .safe
    }
}

@MainActor
private final class Issue7Pasteboard: InsertionPasteboard {
    private(set) var writes: [String] = []
    var writeResult = true

    func write(_ rawText: String) -> Bool {
        writes.append(rawText)
        return writeResult
    }
}

@MainActor
private final class Issue7EventSender: InsertionEventSender {
    private(set) var sendCalls = 0

    func sendPaste(
        to processIdentifier: Int32,
        revalidate: () -> TargetValidation
    ) -> InsertionEventResult {
        _ = processIdentifier
        guard revalidate() == .safe else {
            return .targetUnsafe(.applicationChanged)
        }
        sendCalls += 1
        return .sent
    }
}

private final class Issue7RetryTranscription: TranscriptionController, @unchecked Sendable {
    let finalizedText: String

    init(finalizedText: String) {
        self.finalizedText = finalizedText
    }

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
    }

    func append(_ buffer: AudioCaptureBuffer) {
        _ = buffer
    }

    func finish() async throws -> TranscriptionResult {
        TranscriptionResult(
            finalizedText: finalizedText,
            rawTextByteCount: Int64(finalizedText.utf8.count)
        )
    }

    func cancel() async throws -> TranscriptionResult? {
        nil
    }

    func retrySavedAudio(
        for session: DictationSession,
        store: SessionStore
    ) async throws -> TranscriptionResult {
        let descriptor = try store.openAudioFileDescriptor(for: session)
        defer { descriptor.close() }
        let audioURL = URL(fileURLWithPath: "/dev/fd/\(descriptor.rawValue)")
        let audioBytes = try Data(contentsOf: audioURL)
        let persisted = try store.persistRawText(finalizedText, for: session)
        _ = try store.update(
            persisted,
            state: .completed,
            audioByteCount: Int64(audioBytes.count),
            rawTextByteCount: Int64(finalizedText.utf8.count)
        )
        return TranscriptionResult(
            finalizedText: finalizedText,
            rawTextByteCount: Int64(finalizedText.utf8.count)
        )
    }
}
