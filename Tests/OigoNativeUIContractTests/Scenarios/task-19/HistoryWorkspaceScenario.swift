import Foundation
import OigoCore

final class HistoryWorkspaceScenario: NativeUIContractScenario {
    override class var scenarioName: String { "history-workspace" }

    override class func run(arguments: ContractArguments) throws {
        guard arguments.defaultsSuite == "com.oigo.qa.task19" else {
            throw ContractInputError(category: "invalid-defaults-suite")
        }

        guard OigoHistoryWorkspacePolicy.defaultWidth == 1_000,
              OigoHistoryWorkspacePolicy.defaultHeight == 640,
              OigoHistoryWorkspacePolicy.minimumWidth == 880,
              OigoHistoryWorkspacePolicy.minimumHeight == 520,
              OigoHistoryWorkspacePolicy.initialPageSize == 50,
              OigoHistoryWorkspacePolicy.toolbarItems == ["copy", "paste-again", "playback", "more"] else {
            throw ContractInputError(category: "history-workspace-policy")
        }

        let archetypes: [(DictationSessionState, InsertionOutcome?, Int64?, Int64?, String)] = [
            (.completed, .pasted, 10, 1, "Inserted"),
            (.completed, .dispatched, 10, 1, "Paste attempted"),
            (.completed, .copied, 10, 1, "Copied to Clipboard"),
            (.completed, .pasted, 10, 1, "Cleanup fallback"),
            (.completed, .failed, 10, 1, "Insertion failed"),
            (.failed, nil, 10, 0, "Retry transcription"),
            (.cancelled, nil, 0, 0, "Cancelled before transcript"),
            (.cancelled, nil, 0, 10, "Cancelled; transcript preserved")
        ]

        for (index, archetype) in archetypes.enumerated() {
            let metadata = SessionMetadata(
                id: UUID(),
                directoryName: "session-\(index)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                state: archetype.0,
                audioByteCount: archetype.2,
                rawTextByteCount: archetype.3,
                insertionOutcome: archetype.1,
                cleanupFallbackReason: index == 3 ? "cleaning timed out; raw transcript kept" : nil,
                firstTranscriptLine: "bounded summary"
            )
            let session = DictationSession(metadata: metadata, directoryURL: arguments.fixtureRoot)
            let projection = OigoHistoryRowProjection(
                entry: SessionHistoryEntry(
                    session: session,
                    firstTranscriptLine: "bounded summary",
                    textSource: .raw
                )
            )
            guard projection.statusLabel == archetype.4,
                  projection.summary == "bounded summary",
                  projection.accessibilityLabel.contains(archetype.4) else {
                throw ContractInputError(category: "history-row-archetype")
            }
        }

        print("PASS history-workspace split=1000x640 page=50 rows=8 bodyReads=0")
    }
}
