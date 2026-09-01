import Foundation
import OigoCore

public enum OigoTerminalHUDPresentationState: String, CaseIterable, Equatable, Sendable {
    case terminal
    case pasteAttempted = "paste-attempted"
    case copyOnly = "copy-only"
    case cleanupFallback = "cleanup-fallback"
    case preservedFailure = "preserved-failure"
    case savedRetry = "saved-retry"
    case cancelledBeforeRaw = "cancelled-before-raw"
    case cancelledAfterRaw = "cancelled-after-raw"
    case interrupted
}

public enum OigoSessionPresentationProjection {
    public static func latestSession(
        _ session: DictationSession,
        fileManager: FileManager = .default
    ) -> OigoLatestSessionPresentationInput {
        let state: OigoLatestSessionPresentationState = switch session.metadata.state {
        case .preparing: .preparing
        case .recording: .recording
        case .stopping: .stopping
        case .retrying: .retrying
        case .completed: .complete
        case .failed: .failed
        case .cancelled: .cancelled
        case .interrupted: .interrupted
        }
        return OigoLatestSessionPresentationInput(
            id: session.id,
            state: state,
            createdAt: session.metadata.createdAt,
            hasAudio: (session.metadata.audioByteCount ?? 0) > 0
                && hasDurableContent(at: session.audioURL, fileManager: fileManager),
            hasTranscript: (session.metadata.rawTextByteCount ?? 0) > 0
                && hasDurableContent(at: session.rawTextURL, fileManager: fileManager),
            failure: failure(session.metadata.failureCode),
            durationSeconds: session.metadata.duration.map { max(0, Int($0.rounded())) },
            source: latestSource(session.metadata)
        )
    }

    public static func failure(
        _ code: DictationFailureCode?
    ) -> OigoTerminalPresentationFailure? {
        switch code {
        case .audioWriteFailed:
            .storage
        case .microphonePermissionRevoked:
            .permission
        case .transcriptionFailed:
            .transcription
        case .transcriptionTimedOut:
            .timeout
        case .cleanupTimedOut:
            .cleanup
        case .targetLost:
            .targetLost
        case .audioInputDeviceChanged, .audioInputConfigurationChanged, .audioEngineStartFailed:
            .capture
        case .cancelled, .applicationQuit, .audioEngineInterrupted, .unknownFailure:
            .unknown
        case nil:
            nil
        }
    }

    public static func terminalHUDState(
        for terminal: OigoTerminalPresentationInput,
        latestSession: OigoLatestSessionPresentationInput?
    ) -> OigoTerminalHUDPresentationState {
        switch terminal.outcome {
        case .completed:
            .terminal
        case .pasteAttempted, .pasted:
            .pasteAttempted
        case .copied:
            .copyOnly
        case .cleanupFallback:
            .cleanupFallback
        case .insertionFailed, .failed:
            .preservedFailure
        case .retryRequired:
            .savedRetry
        case .cancelled:
            latestSession?.hasTranscript == true ? .cancelledAfterRaw : .cancelledBeforeRaw
        case .interrupted:
            .interrupted
        }
    }

    private static func latestSource(
        _ metadata: SessionMetadata
    ) -> OigoLatestSessionPresentationSource {
        switch metadata.configurationSnapshot?.processingMode {
        case .instant:
            .instant
        case .clean:
            .clean
        case nil:
            .unknown
        }
    }

    private static func hasDurableContent(
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }
}
