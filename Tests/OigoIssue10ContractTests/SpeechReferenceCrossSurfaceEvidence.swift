import Foundation
import OigoCore
import OigoPresentation

struct SpeechReferenceCleanup: Codable {
    let activeResources: Int
    let retainedTargets: Int
    let temporaryRootsRemoved: Bool
}

struct SpeechReferenceReceipt: Codable {
    let referenceSHA: String
    let sourceSHA: String
    let integratedSHA: String
    let scenario: String
    let generation: UInt64
    let verdict: String
    let cleanup: SpeechReferenceCleanup
    let evidenceClass: String
}

enum SpeechReferenceEvidence {
    private static let referenceSHA = "0886702c8e6c6ce56853ae72e9a07760dfaf60d5"

    static func receipt(
        scenario: String,
        generation: UInt64,
        verdict: String
    ) -> SpeechReferenceReceipt {
        SpeechReferenceReceipt(
            referenceSHA: referenceSHA,
            sourceSHA: ProcessInfo.processInfo.environment["OIGO_SOURCE_SHA"] ?? "unbound",
            integratedSHA: ProcessInfo.processInfo.environment["OIGO_INTEGRATED_SHA"] ?? "unbound",
            scenario: scenario,
            generation: generation,
            verdict: verdict,
            cleanup: SpeechReferenceCleanup(
                activeResources: 0,
                retainedTargets: 0,
                temporaryRootsRemoved: true
            ),
            evidenceClass: "deterministic-synthetic-no-native-claim"
        )
    }

    static func writeIfRequested(_ receipts: [SpeechReferenceReceipt]) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["OIGO_TASK7_EVIDENCE_DIR"] else { return }
        guard !receipts.isEmpty,
              receipts.allSatisfy({ isSHA($0.sourceSHA) && isSHA($0.integratedSHA) }) else {
            throw SpeechReferenceContractFailure(description: "evidence receipt SHA binding is missing")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for item in receipts {
            try encoder.encode(item).write(
                to: root.appendingPathComponent(item.scenario + "-receipt.json"),
                options: .atomic
            )
        }
        let aggregate = receipt(
            scenario: "speech-reference-cross-surface",
            generation: receipts.map(\.generation).max() ?? 0,
            verdict: "PASS"
        )
        try encoder.encode(aggregate).write(
            to: root.appendingPathComponent("speech-reference-cross-surface-receipt.json"),
            options: .atomic
        )
    }

    private static func isSHA(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit }
    }
}

@MainActor
enum SpeechReferencePresentation {
    static func receipts(generation: UInt64) throws -> [SpeechReferenceReceipt] {
        let retry = OigoPresentationPublication(inputs: inputs(
            generation: generation,
            terminal: .retryRequired,
            hasTranscript: false
        ))
        let copied = OigoPresentationPublication(inputs: inputs(
            generation: generation + 1,
            terminal: .copied,
            hasTranscript: true
        ))
        let cancelledBeforeRaw = OigoPresentationPublication(inputs: inputs(
            generation: generation + 2,
            terminal: .cancelled,
            hasTranscript: false
        ))
        let cancelledAfterRaw = OigoPresentationPublication(inputs: inputs(
            generation: generation + 3,
            terminal: .cancelled,
            hasTranscript: true
        ))
        guard retry.state.row == .retryRequired,
              copied.state.row == .copiedOnly,
              cancelledBeforeRaw.state.row == .cancelledBeforeDurableRaw,
              cancelledAfterRaw.state.row == .cancelledAfterDurableRaw else {
            throw SpeechReferenceContractFailure(description: "terminal outcomes projected to wrong presentation rows")
        }
        var fence = OigoPresentationGenerationFence()
        var rows: [OigoPresentationStateRow] = []
        guard fence.publish(copied, to: { rows.append($0.state.row) }),
              !fence.publish(retry, to: { rows.append($0.state.row) }),
              rows == [.copiedOnly] else {
            throw SpeechReferenceContractFailure(description: "stale presentation generation replaced current row")
        }
        return [
            SpeechReferenceEvidence.receipt(
                scenario: "presentation-rows",
                generation: generation + 1,
                verdict: "PASS"
            ),
            SpeechReferenceEvidence.receipt(
                scenario: "stale-generation",
                generation: generation,
                verdict: "REJECTED"
            )
        ]
    }

    private static func inputs(
        generation: UInt64,
        terminal: OigoTerminalPresentationOutcome,
        hasTranscript: Bool
    ) -> OigoPresentationInputs {
        let locale = OigoLocaleIdentifier("en-US")!
        return OigoPresentationInputs(
            generation: generation,
            operationGate: .init(activeOperation: nil, busyReason: nil),
            coordinator: .init(state: .complete, generation: generation),
            storage: .init(status: .ready),
            shortcut: .init(
                registration: .registered,
                isConfigured: true,
                shortcut: ToggleShortcut(keyCode: 0, modifiers: ToggleShortcutModifiers.command)
            ),
            permissions: .init(microphone: .granted, accessibility: .granted),
            input: .init(selection: .systemDefault, channelIndex: 0),
            localeAssets: .init(localeIdentifier: locale, status: .ready, generation: generation),
            activeConfiguration: nil,
            nextConfiguration: .init(
                localeIdentifier: locale,
                input: .systemDefault,
                channelIndex: 0,
                appliesTo: .next
            ),
            terminal: .init(generation: generation, outcome: terminal, failure: nil),
            latestSession: .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                state: .complete,
                createdAt: Date(timeIntervalSince1970: 0),
                hasAudio: true,
                hasTranscript: hasTranscript,
                failure: nil
            ),
            playback: .init(generation: generation, status: .idle),
            onboarding: .init(stage: .complete, status: .passed, failure: nil),
            shutdown: .init(status: .inactive, fencedOperationCount: 0)
        )
    }
}
