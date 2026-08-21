import Foundation

public enum OigoHUDShellPolicy {
    public static let recordingTimerInterval: TimeInterval = 1.0
    public static let previewInterval: TimeInterval = 0.2
    public static let maxPreviewUpdatesPerSecond = 5
    public static let previewMaxCharacters = 180
    public static let previewMaxLines = 2
    public static let ordinaryTerminalDismissal: TimeInterval = 1.8
    public static let actionableTerminalDismissal: TimeInterval = 3.0

    public static func content(for state: OigoHUDState) -> OigoHUDContent {
        switch state {
        case .preparing:
            content(
                title: "Preparing...",
                detail: "Getting ready to record.",
                tone: .informational,
                iconRole: .information
            )
        case .recording:
            content(
                title: "Recording",
                detail: "Release the shortcut to finish.",
                tone: .recording,
                iconRole: .recording,
                showsRecordingElapsed: true,
                allowsPreview: true
            )
        case .degradedRecording:
            content(
                title: "Recording degraded",
                detail: "Audio continues; transcription retry required.",
                tone: .warning,
                iconRole: .attention,
                actionability: .retryTranscription,
                showsRecordingElapsed: true
            )
        case .finalizing:
            content(
                title: "Finalizing...",
                detail: "Finishing the recording.",
                tone: .informational,
                iconRole: .information
            )
        case .cleaning:
            content(
                title: "Cleaning...",
                detail: "Applying the selected cleanup.",
                tone: .informational,
                iconRole: .information
            )
        case .pasting:
            content(
                title: "Pasting...",
                detail: "Sending the result to the current destination.",
                tone: .informational,
                iconRole: .information
            )
        case .pasteAttempted:
            content(
                title: "Paste attempted",
                detail: "Clipboard retained; third-party paste result is unknown.",
                tone: .success,
                iconRole: .confirmation,
                dismissal: .timed(after: ordinaryTerminalDismissal),
                isTerminal: true
            )
        case .copied:
            content(
                title: "Copied to Clipboard",
                detail: "Paste Again remains available.",
                tone: .success,
                iconRole: .confirmation,
                actionability: .pasteAgain,
                dismissal: .timed(after: actionableTerminalDismissal),
                isTerminal: true
            )
        case .copyOnly:
            content(
                title: "Copied to Clipboard",
                detail: "Automatic paste is unavailable; Paste Again remains available.",
                tone: .informational,
                iconRole: .information,
                actionability: .pasteAgain,
                dismissal: .timed(after: actionableTerminalDismissal),
                isTerminal: true
            )
        case .savedRetry:
            content(
                title: "Recording Saved - Retry Needed",
                detail: "Audio is preserved for transcription retry.",
                tone: .warning,
                iconRole: .attention,
                actionability: .retryTranscription,
                dismissal: .timed(after: actionableTerminalDismissal),
                isTerminal: true
            )
        case .preservedFailure:
            content(
                title: "Failed - Recording Preserved",
                detail: "Audio and text are preserved for recovery.",
                tone: .critical,
                iconRole: .failure,
                actionability: .copyAndPasteAgain,
                dismissal: .timed(after: actionableTerminalDismissal),
                isTerminal: true
            )
        case .cleanupFallback:
            content(
                title: "Cleanup fallback",
                detail: "Text preserved; paste was attempted.",
                tone: .warning,
                iconRole: .attention,
                actionability: .pasteAgain,
                dismissal: .timed(after: actionableTerminalDismissal),
                isTerminal: true
            )
        case .cancelledBeforeRaw:
            content(
                title: "Cancelled",
                detail: "Nothing was saved.",
                tone: .neutral,
                iconRole: .information,
                dismissal: .timed(after: ordinaryTerminalDismissal),
                isTerminal: true
            )
        case .cancelledAfterRaw:
            content(
                title: "Cancelled",
                detail: "Recording preserved in History.",
                tone: .informational,
                iconRole: .information,
                actionability: .openHistory,
                dismissal: .timed(after: actionableTerminalDismissal),
                isTerminal: true
            )
        case .interrupted:
            content(
                title: "Interrupted",
                detail: "Recording preserved when available.",
                tone: .warning,
                iconRole: .attention,
                actionability: .openHistory,
                dismissal: .timed(after: actionableTerminalDismissal),
                isTerminal: true
            )
        case .pasteAgainDestination:
            content(
                title: "Choose a destination",
                detail: "Paste Again is waiting for the destination.",
                tone: .informational,
                iconRole: .destination,
                actionability: .chooseDestination
            )
        case .terminal:
            content(
                title: "Complete",
                detail: "Dictation finished.",
                tone: .success,
                iconRole: .confirmation,
                dismissal: .timed(after: ordinaryTerminalDismissal),
                isTerminal: true
            )
        case .shutdown:
            content(
                title: "Quitting...",
                detail: "HUD released.",
                tone: .neutral,
                iconRole: .information,
                dismissal: .hidden,
                isTerminal: true
            )
        }
    }

    public static func boundedPreview(_ text: String) -> String {
        let lines = text
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
        return String(lines.suffix(previewMaxLines).joined(separator: "\n").prefix(previewMaxCharacters))
    }

    public static func isRecording(_ state: OigoHUDState) -> Bool {
        [.recording, .degradedRecording].contains(state)
    }

    private static func content(
        title: String,
        detail: String,
        tone: OigoHUDTone,
        iconRole: OigoHUDIconRole,
        actionability: OigoHUDActionability = .none,
        dismissal: OigoHUDDismissalPolicy = .persistent,
        isTerminal: Bool = false,
        showsRecordingElapsed: Bool = false,
        allowsPreview: Bool = false
    ) -> OigoHUDContent {
        OigoHUDContent(
            title: title,
            detail: detail,
            tone: tone,
            iconRole: iconRole,
            actionability: actionability,
            dismissal: dismissal,
            isTerminal: isTerminal,
            showsRecordingElapsed: showsRecordingElapsed,
            allowsPreview: allowsPreview
        )
    }
}
