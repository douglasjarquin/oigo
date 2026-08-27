import Foundation
import OigoCore

public enum OigoPopoverSection: String, Equatable, Sendable {
    case header
    case primaryAction = "primary-action"
    case shortcut
    case mode
    case microphone
    case notice
    case latestDictation = "latest-dictation"
    case footer
}

public enum OigoPopoverTone: String, Equatable, Sendable {
    case neutral
    case informational
    case success
    case warning
    case critical
    case recording
}

public struct OigoPopoverActionPresentation: Equatable, Sendable {
    public let title: String
    public let action: OigoPresentationAction?
    public let isEnabled: Bool
    public let disabledReason: String?
}

public struct OigoPopoverShortcutPresentation: Equatable, Sendable {
    public let glyphs: [String]
    public let accessibilityLabel: String
    public let isAvailable: Bool
}

public struct OigoPopoverModePresentation: Equatable, Sendable {
    public let selected: OigoProcessingModePresentationValue
    public let isEnabled: Bool
    public let appliesToNextDictation: Bool
    public let instantAction: OigoPresentationAction
    public let cleanAction: OigoPresentationAction
}

public struct OigoPopoverMicrophonePresentation: Equatable, Sendable {
    public let label: String
    public let category: String
    public let tone: OigoPopoverTone
    public let isEnabled: Bool
    public let action: OigoPresentationAction?
}

public struct OigoPopoverNoticePresentation: Equatable, Sendable {
    public let category: String
    public let title: String
    public let body: String
    public let tone: OigoPopoverTone
    public let action: OigoPopoverActionPresentation
}

public struct OigoPopoverLatestPresentation: Equatable, Sendable {
    public let relativeTime: String
    public let duration: String
    public let status: String
    public let source: String
    public let actions: [OigoPopoverActionPresentation]
}

public struct OigoPopoverPresentation: Equatable, Sendable {
    public let row: OigoPresentationStateRow
    public let width: Int
    public let allowsScrolling: Bool
    public let sections: [OigoPopoverSection]
    public let statusLabel: String
    public let statusTone: OigoPopoverTone
    public let primaryAction: OigoPopoverActionPresentation
    public let shortcut: OigoPopoverShortcutPresentation
    public let mode: OigoPopoverModePresentation
    public let microphone: OigoPopoverMicrophonePresentation
    public let notice: OigoPopoverNoticePresentation?
    public let latest: OigoPopoverLatestPresentation?
    public let copyOnly: OigoCopyOnlyPosture

    public static func compose(
        state: OigoPresentationState,
        inputs: OigoPresentationInputs
    ) -> OigoPopoverPresentation {
        let notice = noticePresentation(state.notice)
        var sections: [OigoPopoverSection] = [
            .header, .primaryAction, .shortcut, .mode, .microphone
        ]
        if notice != nil { sections.append(.notice) }
        sections.append(contentsOf: [.latestDictation, .footer])
        return OigoPopoverPresentation(
            row: state.row,
            width: 340,
            allowsScrolling: false,
            sections: sections,
            statusLabel: statusLabel(state.status),
            statusTone: statusTone(state.status, terminal: state.terminal),
            primaryAction: actionPresentation(state.primaryAction),
            shortcut: shortcutPresentation(inputs.shortcut),
            mode: OigoPopoverModePresentation(
                selected: inputs.nextConfiguration.mode,
                isEnabled: state.availability.commandsEnabled,
                appliesToNextDictation: state.nextDictation == .configurationPending
                    && inputs.activeConfiguration != nil,
                instantAction: .setMode(.instant),
                cleanAction: .setMode(.clean)
            ),
            microphone: microphonePresentation(inputs.input, state: state),
            notice: notice,
            latest: latestPresentation(state: state, inputs: inputs),
            copyOnly: state.copyOnly
        )
    }

    private static func statusLabel(_ status: OigoPresentationStatus) -> String {
        switch status {
        case .checking: "Checking…"
        case .ready: "Ready"
        case .readyCopyOnly: "Ready · Copy-only"
        case .attentionNeeded: "Attention Needed"
        case .preparing: "Preparing…"
        case .recording: "Recording"
        case .finalizing: "Finalizing…"
        case .cleaning: "Cleaning…"
        case .inserting: "Pasting…"
        case .busy: "Busy"
        case .quitting: "Quitting…"
        }
    }

    private static func statusTone(
        _ status: OigoPresentationStatus,
        terminal: OigoTerminalPresentationClass?
    ) -> OigoPopoverTone {
        if let terminal {
            switch terminal {
            case .ownedFieldVerified:
                return .success
            case .insertionFailure:
                return .critical
            case .cleanupFallback, .retryRequired, .interruption,
                 .cancellation(.afterDurableRaw):
                return .warning
            case .pasteAttempted, .copied, .cancellation(.beforeDurableRaw),
                 .busy, .shutdown:
                return .informational
            }
        }
        switch status {
        case .attentionNeeded: return .warning
        case .recording: return .recording
        case .readyCopyOnly: return .informational
        default: return .neutral
        }
    }

    private static func actionPresentation(
        _ action: OigoPrimaryPresentationAction
    ) -> OigoPopoverActionPresentation {
        switch action {
        case .enabled(let action):
            return .init(title: actionTitle(action), action: action, isEnabled: true, disabledReason: nil)
        case .disabled(let action, let reason):
            return .init(
                title: action.map(actionTitle) ?? disabledTitle(reason),
                action: action,
                isEnabled: false,
                disabledReason: reason.category
            )
        }
    }

    private static func actionTitle(_ action: OigoPresentationAction) -> String {
        switch action {
        case .startDictation: "Start Dictation"
        case .stopDictation: "Stop Dictation"
        case .retryStorage: "Retry Storage"
        case .retryTranscription: "Retry Transcription"
        case .chooseInput: "Choose Input"
        case .installAssets: "Install"
        case .openSettings: "Open Settings"
        case .openSystemSettings: "Open System Settings"
        case .setMode: "Set Mode"
        case .openDataLocation: "Open Data Location"
        case .copy: "Copy"
        case .pasteAgain: "Paste Again"
        case .openHistory: "Open History"
        case .quit: "Quit Oigo"
        }
    }

    private static func disabledTitle(_ reason: OigoActionDisabledReason) -> String {
        switch reason {
        case .checking: "Checking…"
        case .storageUnavailable: "Storage Unavailable"
        case .microphoneUnavailable: "Microphone Unavailable"
        case .selectedInputUnavailable: "Input Unavailable"
        case .languageAssetsUnavailable: "Speech Assets Unavailable"
        case .busy(.shutdown), .shuttingDown: "Quitting…"
        case .busy(.occupied(let kind)): "Busy · " + busyLabel(kind)
        }
    }

    private static func busyLabel(_ kind: OigoPresentationOperationKind) -> String {
        switch kind {
        case .dictation, .onboardingTest: "Dictation"
        case .retry: "Retry"
        case .cleanAgain: "Clean Again"
        case .reapplyDictionary: "Dictionary"
        case .pasteAgain: "Paste Again"
        case .interruption: "Interruption"
        case .shutdown: "Shutdown"
        case .maintenance: "Maintenance"
        }
    }

    private static func shortcutPresentation(
        _ shortcut: OigoShortcutPresentationInput
    ) -> OigoPopoverShortcutPresentation {
        let names = shortcut.displayName.split(separator: "-").map(String.init)
        let glyphs = names.map { component -> String in
            switch component {
            case "Shift": "⇧"
            case "Control": "⌃"
            case "Option": "⌥"
            case "Command": "⌘"
            default: component
            }
        }
        return .init(
            glyphs: glyphs,
            accessibilityLabel: shortcut.displayName.replacingOccurrences(of: "-", with: " "),
            isAvailable: shortcut.registration == .registered && shortcut.isConfigured
        )
    }

    private static func microphonePresentation(
        _ input: OigoInputPresentationInput,
        state: OigoPresentationState
    ) -> OigoPopoverMicrophonePresentation {
        switch input.selection {
        case .systemDefault:
            return .init(label: "System Default", category: "system-default", tone: .neutral,
                         isEnabled: state.availability.commandsEnabled, action: .chooseInput)
        case .pinnedAvailable:
            return .init(label: "Pinned Input", category: "pinned-input", tone: .neutral,
                         isEnabled: state.availability.commandsEnabled, action: .chooseInput)
        case .pinnedUnavailable:
            return .init(label: "Pinned Input - Unavailable", category: "pinned-input-unavailable",
                         tone: .warning, isEnabled: state.availability.commandsEnabled,
                         action: .chooseInput)
        case .noAvailableInput:
            return .init(label: "No Input Available", category: "no-input", tone: .critical,
                         isEnabled: state.availability.commandsEnabled, action: .chooseInput)
        }
    }

    private static func noticePresentation(_ category: OigoNotice?) -> OigoPopoverNoticePresentation? {
        guard let category else { return nil }
        switch category {
        case .storageCritical:
            return makeNotice(category, "Storage unavailable",
                          "Oigo cannot create durable recordings right now.", .critical, .retryStorage)
        case .microphonePermission:
            return makeNotice(category, "Microphone unavailable",
                          "Allow microphone access before starting dictation.", .warning,
                          .openSystemSettings(OigoPermissionPresentation.microphone(.denied).settingsURL))
        case .selectedInput:
            return makeNotice(category, "Selected input unavailable",
                          "Reconnect the pinned input or choose another microphone.", .warning,
                          .chooseInput)
        case .languageAssets:
            return makeNotice(category, "Speech assets required",
                          "The selected language needs on-device speech assets.", .warning,
                          .installAssets)
        case .retryRequired:
            return makeNotice(category, "Recording preserved",
                          "Live transcription degraded. The recording is available for retry.", .warning,
                          .retryTranscription)
        case .interruption:
            return makeNotice(category, "Dictation interrupted",
                          "Available durable work remains in History.", .warning, .openHistory)
        case .shortcutConflict:
            return makeNotice(category, "Shortcut inactive",
                          "The configured shortcut is unavailable. Mouse start remains available.", .warning,
                          .openSettings)
        case .accessibilityCopyOnly:
            return makeNotice(category, "Accessibility unavailable",
                          "Oigo will copy results instead of pasting automatically.", .informational,
                          .openSystemSettings(OigoPermissionPresentation.accessibility(.denied).settingsURL))
        }
    }

    private static func makeNotice(
        _ category: OigoNotice,
        _ title: String,
        _ body: String,
        _ tone: OigoPopoverTone,
        _ action: OigoPresentationAction
    ) -> OigoPopoverNoticePresentation {
        .init(
            category: category.category,
            title: title,
            body: body,
            tone: tone,
            action: .init(title: actionTitle(action), action: action, isEnabled: true,
                          disabledReason: nil)
        )
    }

    private static func latestPresentation(
        state: OigoPresentationState,
        inputs: OigoPresentationInputs
    ) -> OigoPopoverLatestPresentation? {
        guard let latest = inputs.latestSession else { return nil }
        var actions = [state.latestSessionActions.primary, state.latestSessionActions.secondary]
            .compactMap { $0 }
            .map(latestAction)
        if actions.isEmpty, latest.hasTranscript {
            actions = [latestAction(.copy), latestAction(.pasteAgain)]
        }
        return .init(
            relativeTime: relativeTime(from: latest.createdAt, to: inputs.presentationDate),
            duration: duration(latest.durationSeconds),
            status: latestStatus(latest, terminal: state.terminal),
            source: latest.source.rawValue.capitalized,
            actions: actions
        )
    }

    private static func latestAction(_ action: OigoLatestSessionAction) -> OigoPopoverActionPresentation {
        let mapped: OigoPresentationAction = switch action {
        case .retryTranscription: .retryTranscription
        case .copy: .copy
        case .pasteAgain: .pasteAgain
        case .openHistory: .openHistory
        }
        return .init(title: actionTitle(mapped), action: mapped, isEnabled: true, disabledReason: nil)
    }

    private static func relativeTime(from date: Date, to reference: Date) -> String {
        let seconds = max(0, Int(reference.timeIntervalSince(date)))
        if seconds < 60 { return "Just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3_600) hr ago" }
        return "\(seconds / 86_400) d ago"
    }

    private static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func latestStatus(
        _ latest: OigoLatestSessionPresentationInput,
        terminal: OigoTerminalPresentationClass?
    ) -> String {
        if let terminal {
            switch terminal {
            case .pasteAttempted: return "Paste attempted"
            case .ownedFieldVerified: return "Verified in Oigo"
            case .copied: return "Copied to Clipboard"
            case .cleanupFallback: return "Completed · Fallback kept"
            case .insertionFailure: return "Paste failed · Text preserved"
            case .retryRequired: return "Recording saved · Retry needed"
            case .cancellation(.beforeDurableRaw): return "Cancelled"
            case .cancellation(.afterDurableRaw): return "Cancelled · Saved in History"
            case .interruption: return "Interrupted · Saved in History"
            case .busy, .shutdown: break
            }
        }
        switch latest.state {
        case .preparing: return "Preparing"
        case .recording: return "Recording"
        case .stopping: return "Finalizing"
        case .retrying: return "Retrying"
        case .complete: return "Complete"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        }
    }
}
