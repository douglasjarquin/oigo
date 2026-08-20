import Darwin
import Foundation
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
private struct OigoIssue13ContractTests {
    static func main() async {
        do {
            try testFixtureTermsNormalizeExactly()
            print("GREEN: Consigliere, n8n, Claude Code, and ChatGPT fixtures normalize exactly")
            try testLongestMatchWins()
            print("GREEN: overlapping aliases prefer the longest phrase")
            try testConflictingAliasesAreRejected()
            print("GREEN: conflicting aliases are rejected before use")
            try testPunctuationCapitalizationPossessivePluralAndIdentifiers()
            print("GREEN: punctuation, capitalization, possessive, plural, and identifier boundaries hold")
            try testProtectedSpansAreLeftUntouched()
            print("GREEN: URLs, emails, paths, and code spans are protected")
            try testLocaleSpecificAndDisabledEntries()
            print("GREEN: locale-specific and disabled entries compile correctly")
            try testMissingAndCorruptDictionaryFiles()
            print("GREEN: missing, corrupt, and unsupported dictionaries leave source untouched")
            try testAtomicWriteNoFollowAndBoundedSize()
            print("GREEN: dictionary writes are atomic, no-follow, and bounded")
            try testDeleteAllHistoryDoesNotDeleteDictionary()
            print("GREEN: Delete All History does not delete the dictionary file")
            try await testInstantInsertsNormalizedWithoutFoundationModels()
            print("GREEN: Instant inserts normalized text without Foundation Models")
            try await testCleanNormalizesBeforeAndAfterAndFallsBack()
            print("GREEN: Clean normalizes before and after generated output")
            try await testReapplyDictionaryFromRawWithoutAudio()
            print("GREEN: Reapply Dictionary uses raw text and invalidates stale clean")
            try testLiveAndRetryReceiveCanonicalContextOnce()
            print("GREEN: live and retry Speech paths receive canonical terms once per analysis")
            try testNormalizationPerformance()
            print("GREEN: 500-entry / 10,000-word normalize stays within budget")
            try testExistingSessionsLoadWithoutNormalizedMetadata()
            print("GREEN: existing sessions without normalized metadata still load")
            exit(0)
        } catch {
            print("FAIL: " + String(describing: error))
            exit(1)
        }
    }

    private static func fixtureEntries() -> [DictionaryEntry] {
        [
            DictionaryEntry(
                canonical: "Consigliere",
                aliases: ["consiliary", "conciliere", "con silly air"]
            ),
            DictionaryEntry(
                canonical: "n8n",
                aliases: ["n eight n", "n 8 n", "nate n"]
            ),
            DictionaryEntry(
                canonical: "Claude Code",
                aliases: ["clawed code", "cloud code"]
            ),
            DictionaryEntry(
                canonical: "ChatGPT",
                aliases: ["chat gpt", "chat G P T", "chagpt", "Chad GPT"]
            )
        ]
    }

    private static func fixtureNormalizer() throws -> TerminologyNormalizer {
        let snapshot = try DictionaryCompiler.compile(fixtureEntries(), localeIdentifier: "en-US")
        return TerminologyNormalizer(snapshot: snapshot)
    }

    private static func testFixtureTermsNormalizeExactly() throws {
        let normalizer = try fixtureNormalizer()
        let cases: [(String, String)] = [
            ("the consiliary advised", "the Consigliere advised"),
            ("conciliere opened the door", "Consigliere opened the door"),
            ("ask con silly air next", "ask Consigliere next"),
            ("run n eight n please", "run n8n please"),
            ("start n 8 n now", "start n8n now"),
            ("nate n finished", "n8n finished"),
            ("open clawed code today", "open Claude Code today"),
            ("the cloud code session", "the Claude Code session"),
            ("ask chat gpt later", "ask ChatGPT later"),
            ("try chat G P T again", "try ChatGPT again"),
            ("chagpt replied", "ChatGPT replied"),
            ("Chad GPT wrote this", "ChatGPT wrote this")
        ]
        for (input, expected) in cases {
            let output = normalizer.normalize(input)
            guard output == expected else {
                throw ContractFailure(
                    message: "fixture mismatch: expected \(expected) from \(input), got \(output)"
                )
            }
        }
        guard DictionaryStarterTerms.technology.contains(where: { $0.canonical == "Consigliere" }) == false else {
            throw ContractFailure(message: "starter terms silently included Consigliere")
        }
    }

    private static func testLongestMatchWins() throws {
        let entries = [
            DictionaryEntry(canonical: "Alpha", aliases: ["n eight"]),
            DictionaryEntry(canonical: "n8n", aliases: ["n eight n"])
        ]
        let snapshot = try DictionaryCompiler.compile(entries, localeIdentifier: nil)
        let output = TerminologyNormalizer(snapshot: snapshot).normalize("run n eight n today")
        guard output == "run n8n today" else {
            throw ContractFailure(message: "longest phrase did not win: \(output)")
        }
    }

    private static func testConflictingAliasesAreRejected() throws {
        let entries = [
            DictionaryEntry(canonical: "Alpha", aliases: ["shared"]),
            DictionaryEntry(canonical: "Beta", aliases: ["SHARED"])
        ]
        do {
            _ = try DictionaryCompiler.compile(entries, localeIdentifier: nil)
            throw ContractFailure(message: "conflicting aliases were accepted")
        } catch let error as DictionaryStoreError {
            guard case .conflictingAlias = error else {
                throw ContractFailure(message: "conflict returned the wrong error")
            }
        }
        do {
            _ = try DictionaryCompiler.compile(
                [DictionaryEntry(canonical: "Alpha", aliases: ["dup", "DUP"])],
                localeIdentifier: nil
            )
            throw ContractFailure(message: "duplicate aliases within an entry were accepted")
        } catch let error as DictionaryStoreError {
            guard error == .duplicateAliasInEntry else {
                throw ContractFailure(message: "duplicate alias returned the wrong error")
            }
        }
    }

    private static func testPunctuationCapitalizationPossessivePluralAndIdentifiers() throws {
        let normalizer = try fixtureNormalizer()
        let cases: [(String, String)] = [
            ("(conciliere)", "(Consigliere)"),
            ("consiliary.", "Consigliere."),
            ("CONSILIARY", "Consigliere"),
            ("consiliary's notes", "Consigliere's notes"),
            ("Consigliere's", "Consigliere's"),
            ("Consiglieres stayed", "Consiglieres stayed"),
            ("n8n_job failed", "n8n_job failed"),
            ("xconsiliary", "xconsiliary")
        ]
        for (input, expected) in cases {
            let output = normalizer.normalize(input)
            guard output == expected else {
                throw ContractFailure(message: "boundary mismatch for \(input): \(output)")
            }
        }
    }

    private static func testProtectedSpansAreLeftUntouched() throws {
        let normalizer = try fixtureNormalizer()
        let input = """
        visit https://n8n.io and mail ops@n8n.io then /tmp/n8n_job.yaml
        ```
        n eight n
        ```
        use `n8n_job` and keep n eight n outside
        """
        let output = normalizer.normalize(input)
        guard output.contains("https://n8n.io"),
              output.contains("ops@n8n.io"),
              output.contains("/tmp/n8n_job.yaml"),
              output.contains("```\nn eight n\n```"),
              output.contains("`n8n_job`"),
              output.contains("keep n8n outside") else {
            throw ContractFailure(message: "protected spans were rewritten: \(output)")
        }
    }

    private static func testLocaleSpecificAndDisabledEntries() throws {
        let entries = [
            DictionaryEntry(canonical: "GlobalTerm", aliases: ["global alias"]),
            DictionaryEntry(
                canonical: "EnglishTerm",
                aliases: ["english alias"],
                localeIdentifier: "en-US"
            ),
            DictionaryEntry(
                canonical: "FrenchTerm",
                aliases: ["french alias"],
                localeIdentifier: "fr-FR"
            ),
            DictionaryEntry(
                canonical: "DisabledTerm",
                aliases: ["disabled alias"],
                isEnabled: false
            )
        ]
        let english = try DictionaryCompiler.compile(entries, localeIdentifier: "en-US")
        let french = try DictionaryCompiler.compile(entries, localeIdentifier: "fr-FR")
        let englishOutput = TerminologyNormalizer(snapshot: english)
            .normalize("global alias english alias french alias disabled alias")
        let frenchOutput = TerminologyNormalizer(snapshot: french)
            .normalize("global alias english alias french alias disabled alias")
        guard english.canonicalTerms == ["GlobalTerm", "EnglishTerm"],
              french.canonicalTerms == ["GlobalTerm", "FrenchTerm"],
              englishOutput == "GlobalTerm EnglishTerm french alias disabled alias",
              frenchOutput == "GlobalTerm english alias FrenchTerm disabled alias" else {
            throw ContractFailure(message: "locale or disabled compilation was wrong")
        }
    }

    private static func testMissingAndCorruptDictionaryFiles() throws {
        let root = temporaryDirectory("missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DictionaryStore(directoryURL: root)
        let missing = store.load()
        guard missing.document.entries.isEmpty,
              missing.error == nil,
              !FileManager.default.fileExists(atPath: store.fileURL.path) else {
            throw ContractFailure(message: "missing dictionary did not load as empty")
        }

        let corruptBytes = Data("{not-json".utf8)
        try corruptBytes.write(to: store.fileURL, options: [.atomic])
        let corrupt = store.load()
        guard corrupt.document.entries.isEmpty,
              corrupt.error == .malformed,
              try Data(contentsOf: store.fileURL) == corruptBytes else {
            throw ContractFailure(message: "corrupt dictionary mutated the source file")
        }

        let unsupported = DictionaryDocument(schemaVersion: 99, entries: [])
        let encoder = JSONEncoder()
        let unsupportedData = try encoder.encode(unsupported)
        try unsupportedData.write(to: store.fileURL, options: [.atomic])
        let loadedUnsupported = store.load()
        guard loadedUnsupported.document.entries.isEmpty,
              loadedUnsupported.error == .unsupportedVersion,
              try Data(contentsOf: store.fileURL) == unsupportedData else {
            throw ContractFailure(message: "unsupported version mutated the source file")
        }
    }

    private static func testAtomicWriteNoFollowAndBoundedSize() throws {
        let root = temporaryDirectory("atomic")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DictionaryStore(directoryURL: root)
        let document = DictionaryDocument(entries: fixtureEntries())
        try store.save(document)
        let loaded = store.load()
        guard loaded.document.entries.map(\.canonical) == document.entries.map(\.canonical) else {
            throw ContractFailure(message: "saved dictionary did not round-trip")
        }

        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("secret".utf8).write(to: outside, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: outside)
        let followed = store.load()
        guard followed.error == .symlinkRejected,
              try String(contentsOf: outside, encoding: .utf8) == "secret" else {
            throw ContractFailure(message: "dictionary load followed a symlink")
        }
        do {
            try store.save(document)
            throw ContractFailure(message: "dictionary save followed a symlink")
        } catch let error as DictionaryStoreError {
            guard error == .symlinkRejected,
                  try String(contentsOf: outside, encoding: .utf8) == "secret" else {
                throw ContractFailure(message: "symlink save mutated the destination")
            }
        }

        let huge = Data(repeating: 0x61, count: DictionaryStore.maxBytes + 1)
        try FileManager.default.removeItem(at: store.fileURL)
        try huge.write(to: store.fileURL, options: [.atomic])
        let oversized = store.load()
        guard oversized.error == .tooLarge,
              FileManager.default.fileExists(atPath: store.fileURL.path) else {
            throw ContractFailure(message: "oversized dictionary was rewritten")
        }
    }

    private static func testDeleteAllHistoryDoesNotDeleteDictionary() throws {
        let applicationSupport = temporaryDirectory("app-support")
        defer { try? FileManager.default.removeItem(at: applicationSupport) }
        let sessions = applicationSupport.appendingPathComponent("Sessions", isDirectory: true)
        let dictionaryStore = try DictionaryStore(directoryURL: applicationSupport)
        try dictionaryStore.save(DictionaryDocument(entries: fixtureEntries()))
        let sessionStore = try SessionStore(rootDirectory: sessions)
        let session = try sessionStore.persistRawText("raw", for: sessionStore.createSession())
        _ = try sessionStore.persistNormalizedText("raw", for: session)
        _ = try sessionStore.deleteAllHistory(confirmed: true)
        guard FileManager.default.fileExists(atPath: dictionaryStore.fileURL.path),
              dictionaryStore.load().document.entries.count == 4 else {
            throw ContractFailure(message: "Delete All History removed the dictionary")
        }
    }

    private static func testInstantInsertsNormalizedWithoutFoundationModels() async throws {
        let factory = RecordingCleanerFactory()
        let coordinator = TranscriptCleanupCoordinator(cleanerFactory: factory.make)
        let root = temporaryDirectory("instant")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let rawText = "ask consiliary and chat gpt"
        let session = try store.persistRawText(rawText, for: store.createSession())
        let snapshot = try DictionaryCompiler.compile(fixtureEntries(), localeIdentifier: "en-US")
        let result = try await DictionaryTranscriptFinalizer.resolve(
            mode: .instant,
            session: session,
            store: store,
            snapshot: snapshot,
            cleanup: coordinator,
            deadlineNanoseconds: 1_000_000
        )
        guard factory.instantiationCount == 0,
              result.decision.insertionSource == .normalized,
              result.decision.insertionText == "ask Consigliere and ChatGPT",
              try store.readRawText(for: result.session) == rawText,
              try store.readNormalizedText(for: result.session) == "ask Consigliere and ChatGPT" else {
            throw ContractFailure(message: "Instant mode did not insert normalized text")
        }
        let snapshotTarget = InsertionTargetSnapshot(
            frontmostProcessIdentifier: 7,
            bundleIdentifier: "com.example.target",
            focusedElementIdentifier: "field",
            role: "AXTextField",
            isSecureTextField: false
        )
        let pasteboard = ContractPasteboard()
        let insertion = InsertionService(
            targetEnvironment: ContractTargetEnvironment(snapshot: snapshotTarget),
            pasteboard: pasteboard,
            eventSender: ContractEventSender()
        )
        _ = insertion.insertText(
            for: result.session,
            source: .normalized,
            store: store,
            target: snapshotTarget
        )
        guard pasteboard.value == "ask Consigliere and ChatGPT",
              try store.readRawText(for: result.session) == rawText else {
            throw ContractFailure(message: "normalized insertion changed raw.txt")
        }
    }

    private static func testCleanNormalizesBeforeAndAfterAndFallsBack() async throws {
        let recorder = ChunkRecorder()
        let coordinator = TranscriptCleanupCoordinator(
            cleanerFactory: {
                RecordingCleaner(recorder: recorder, output: "please deploy octa now")
            }
        )
        let root = temporaryDirectory("clean")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let rawText = "please deploy octa now"
        let session = try store.persistRawText(rawText, for: store.createSession())
        let snapshot = try DictionaryCompiler.compile(
            [DictionaryEntry(canonical: "okta", aliases: ["octa"])],
            localeIdentifier: "en-US"
        )
        let result = try await DictionaryTranscriptFinalizer.resolve(
            mode: .clean,
            session: session,
            store: store,
            snapshot: snapshot,
            cleanup: coordinator,
            deadlineNanoseconds: 1_000_000_000
        )
        let received = await recorder.values()
        guard received == ["please deploy okta now"],
              result.decision.insertionSource == .clean,
              result.decision.insertionText == "please deploy okta now",
              try store.readRawText(for: result.session) == rawText,
              try store.readCleanText(for: result.session) == "please deploy okta now" else {
            throw ContractFailure(
                message: "Clean did not normalize before and after cleanup: received=\(received) source=\(result.decision.insertionSource) text=\(result.decision.insertionText)"
            )
        }

        let fallbackCoordinator = TranscriptCleanupCoordinator(
            cleanerFactory: { FixedResultCleaner(result: .timedOut) }
        )
        let stale = try store.persistCleanText("stale clean", for: result.session)
        let fallback = try await DictionaryTranscriptFinalizer.resolve(
            mode: .clean,
            session: stale,
            store: store,
            snapshot: snapshot,
            cleanup: fallbackCoordinator,
            deadlineNanoseconds: 10_000_000
        )
        guard fallback.decision.insertionSource == .normalized,
              fallback.decision.insertionText == "please deploy okta now",
              try store.readRawText(for: fallback.session) == rawText,
              try store.readCleanText(for: fallback.session).isEmpty else {
            throw ContractFailure(message: "Clean fallback did not insert normalized text")
        }
    }

    private static func testReapplyDictionaryFromRawWithoutAudio() async throws {
        let root = temporaryDirectory("reapply")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let rawText = "ask consiliary"
        let session = try store.persistRawText(rawText, for: store.createSession())
        let first = try DictionaryCompiler.compile(fixtureEntries(), localeIdentifier: "en-US")
        let created = try await DictionaryTranscriptFinalizer.resolve(
            mode: .clean,
            session: session,
            store: store,
            snapshot: first,
            cleanup: TranscriptCleanupCoordinator(
                cleanerFactory: { FixedResultCleaner(result: .success("ask Consigliere")) }
            ),
            deadlineNanoseconds: 1_000_000_000
        )
        try Data([0x43, 0x41, 0x46]).write(to: created.session.audioURL, options: [.atomic])
        let audioBefore = try Data(contentsOf: created.session.audioURL)
        let updatedEntries = [
            DictionaryEntry(canonical: "Advisor", aliases: ["consiliary"])
        ]
        let updated = try DictionaryCompiler.compile(updatedEntries, localeIdentifier: "en-US")
        let reapplied = try await DictionaryTranscriptFinalizer.reapply(
            session: created.session,
            store: store,
            snapshot: updated,
            cleanup: TranscriptCleanupCoordinator(
                cleanerFactory: { FixedResultCleaner(result: .timedOut) }
            ),
            deadlineNanoseconds: 10_000_000
        )
        guard try store.readRawText(for: reapplied.session) == rawText,
              try store.readNormalizedText(for: reapplied.session) == "ask Advisor",
              try store.readCleanText(for: reapplied.session).isEmpty,
              try Data(contentsOf: created.session.audioURL) == audioBefore,
              reapplied.decision.insertionSource == .normalized else {
            throw ContractFailure(message: "Reapply Dictionary did not preserve raw or invalidate stale clean")
        }
    }

    private static func testLiveAndRetryReceiveCanonicalContextOnce() throws {
        let snapshot = try DictionaryCompiler.compile(fixtureEntries(), localeIdentifier: "en-US")
        let service = TranscriptionService()
        service.applyRecognitionContext(snapshot)
        _ = service.makeAnalysisContext(path: .live)
        _ = service.makeAnalysisContext(path: .retry)
        let terms = service.lastRecordedAnalysisContextTerms
        let paths = service.lastRecordedAnalysisPaths
        guard terms.count == 2,
              paths == [.live, .retry],
              terms[0] == snapshot.canonicalTerms,
              terms[1] == snapshot.canonicalTerms,
              snapshot.canonicalTerms == ["Consigliere", "n8n", "Claude Code", "ChatGPT"] else {
            throw ContractFailure(message: "Speech analysis context was not supplied once per analysis")
        }
    }

    private static func testNormalizationPerformance() throws {
        var entries: [DictionaryEntry] = []
        entries.reserveCapacity(500)
        for index in 0..<500 {
            let token = String(format: "Term%03d", index)
            entries.append(
                DictionaryEntry(
                    canonical: token,
                    aliases: [String(format: "alias%03d", index), String(format: "alt %03d", index)]
                )
            )
        }
        let snapshot = try DictionaryCompiler.compile(entries, localeIdentifier: nil)
        let normalizer = TerminologyNormalizer(snapshot: snapshot)
        var words: [String] = []
        words.reserveCapacity(10_000)
        for index in 0..<10_000 {
            if index.isMultiple(of: 50) {
                words.append(String(format: "alias%03d", (index / 50) % 500))
            } else {
                words.append("word")
            }
        }
        let transcript = words.joined(separator: " ")
        _ = normalizer.normalize(transcript)
        var samples: [UInt64] = []
        samples.reserveCapacity(21)
        for _ in 0..<21 {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = normalizer.normalize(transcript)
            samples.append(DispatchTime.now().uptimeNanoseconds &- started)
        }
        let sorted = samples.sorted()
        let p50 = Double(sorted[10]) / 1_000_000
        let p95 = Double(sorted[19]) / 1_000_000
        print("NORMALIZE_BENCH p50_ms=\(p50) p95_ms=\(p95)")
        guard p95 < 200 else {
            throw ContractFailure(message: "normalize p95 \(p95)ms exceeded 200ms")
        }
    }

    private static func testExistingSessionsLoadWithoutNormalizedMetadata() throws {
        let root = temporaryDirectory("legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(rootDirectory: root)
        let session = try store.persistRawText("legacy raw", for: store.createSession())
        let reloaded = try store.load(id: session.id)
        guard reloaded.metadata.normalizedTextRevision == 0,
              reloaded.metadata.normalizedFromRawRevision == nil,
              try store.readNormalizedText(for: reloaded).isEmpty,
              try store.readRawText(for: reloaded) == "legacy raw" else {
            throw ContractFailure(message: "legacy sessions were rewritten")
        }
    }

    private static func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("oigo-issue13-\(name)-\(UUID().uuidString)", isDirectory: true)
    }
}

@available(macOS 26.0, *)
private final class RecordingCleanerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var instantiationCount = 0

    func make() -> TranscriptCleaner {
        lock.lock()
        instantiationCount += 1
        lock.unlock()
        return FixedResultCleaner(result: .success("should not run"))
    }
}

private actor ChunkRecorder {
    private var chunks: [String] = []

    func record(_ chunk: String) {
        chunks.append(chunk)
    }

    func values() -> [String] {
        chunks
    }
}

@available(macOS 26.0, *)
private struct RecordingCleaner: TranscriptCleaner {
    let recorder: ChunkRecorder
    let output: String

    func availability() -> TranscriptCleanupAvailability {
        .available
    }

    func cancel() {}

    func clean(chunk: String, deadlineNanoseconds: UInt64) async -> TranscriptCleanupGeneration {
        _ = deadlineNanoseconds
        await recorder.record(chunk)
        return .success(output)
    }
}

@available(macOS 26.0, *)
private struct FixedResultCleaner: TranscriptCleaner {
    let result: TranscriptCleanupGeneration

    func availability() -> TranscriptCleanupAvailability {
        .available
    }

    func cancel() {}

    func clean(chunk: String, deadlineNanoseconds: UInt64) async -> TranscriptCleanupGeneration {
        _ = chunk
        _ = deadlineNanoseconds
        return result
    }
}

@MainActor
private final class ContractTargetEnvironment: InsertionTargetEnvironment {
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
private final class ContractPasteboard: InsertionPasteboard {
    private(set) var value: String?

    func write(_ rawText: String) -> Bool {
        value = rawText
        return true
    }
}

@MainActor
private final class ContractEventSender: InsertionEventSender {
    func sendPaste(
        to processIdentifier: Int32,
        revalidate: () -> TargetValidation
    ) -> InsertionEventResult {
        _ = processIdentifier
        return revalidate() == .safe ? .dispatched : .failed
    }
}
